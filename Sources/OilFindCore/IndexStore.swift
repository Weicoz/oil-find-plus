import Foundation
import Darwin

/// v4 索引文件的整份 mmap 视图（MAP_PRIVATE，写时复制）。
/// 未被改写的文件页是干净页，不计入 phys_footprint；只有真正写过的段才变成匿名内存。
internal struct IndexFileMapping {
    let base: UnsafeMutableRawPointer
    let length: Int
    let offsets: [Int]
    let sizes: [Int]
    let capacities: IndexStore.Capacities
    func pointer<T>(_ type: T.Type, _ section: IndexStore.Section) -> UnsafeMutablePointer<T>? {
        let index = section.rawValue, stride = MemoryLayout<T>.stride
        let elements = sizes[index] / stride
        guard elements > 0 else { return nil }
        return base.advanced(by: offsets[index]).bindMemory(to: T.self, capacity: elements)
    }
}

public final class IndexStore {
    /// v4 文件里的段；顺序即文件布局顺序。
    internal enum Section: Int, CaseIterable {
        case nameOff, parent, sizeC, mtime, flags, depth, kind, names, altOff, altOwner, altNames, table, coverage
    }
    internal struct Capacities: Equatable {
        var entries = 0, names = 0, alt = 0, altNames = 0, table = 0, coverage = 0
    }
    /// 段的来源：malloc（含预留余量）或整份 mmap。
    internal enum Backing { case fresh, mapped(IndexFileMapping) }
    internal struct FileLayout { let offsets: [Int], sizes: [Int], total: Int }
    public internal(set) var rootPath: String
    public let caseSensitiveNames: Bool
    public internal(set) var count: Int, namesLen: Int, altCount: Int, altLen: Int
    public internal(set) var capacity: Int, namesCapacity: Int, altCapacity: Int, altNamesCapacity: Int
    public internal(set) var configFingerprint: UInt64
    internal var scopeFingerprint: UInt64 = 0
    public var homeIndex: UInt32, deletedCount: UInt32 = 0, liveCount: Int
    public var version: UInt64 = 0, lastEventId: UInt64 = 0, scanFinishedAt: UInt64
    public var coverage = CoverageStats()
    public var fsEventsUUID: String = ""
    public internal(set) var nameOff: UnsafeMutablePointer<UInt32>, parent: UnsafeMutablePointer<UInt32>
    public internal(set) var sizeC: UnsafeMutablePointer<UInt32>, mtime: UnsafeMutablePointer<UInt32>
    public internal(set) var flags: UnsafeMutablePointer<UInt8>, depth: UnsafeMutablePointer<UInt8>, kind: UnsafeMutablePointer<UInt8>
    public internal(set) var names: UnsafeMutablePointer<UInt8>
    public internal(set) var altOff: UnsafeMutablePointer<UInt32>, altOwner: UnsafeMutablePointer<UInt32>, altNames: UnsafeMutablePointer<UInt8>
    public internal(set) var table: UnsafeMutablePointer<UInt32>?
    public internal(set) var tableCapacity = 0
    // Read under the store lock, as with other store properties.
    public var hashReady: Bool { table != nil }
    internal var tableUsed = 0
    /// 数据写入计数：接管映射前用它证明「快照之后没有人写过」。version 由调用方自增，
    /// 漏掉一次就会让接管把新写入回退掉；计数器由 store 自己在每次写入时自增，不依赖调用方。
    internal private(set) var mutationCount: UInt64 = 0
    /// 记一次数据写入。setter 只在本文件可见，改写入口（IndexStore+Mutation.swift）通过它自增。
    internal func noteMutation() { mutationCount &+= 1 }
    internal var fullKey: [UInt8] = [], initialKey: [UInt8] = []
    /// 非零位表示该段是 malloc 出来的（可 realloc、需要 free）；为零表示指向文件映射。
    private var ownedMask: UInt16 = 0
    /// 因写入而从映射拷回堆的段数；> 0 表示索引已有匿名内存驻留。
    private var heapSections = 0
    /// 记一次「映射段被拷回堆」。setter 只在本文件可见。
    internal func noteHeapSection() { heapSections += 1 }
    private var mapping: IndexFileMapping?
    private var rwlock = pthread_rwlock_t()
    private static func alloc<T>(_ type: T.Type, _ count: Int) -> UnsafeMutablePointer<T> {
        let ptr = malloc(max(1, count) * MemoryLayout<T>.stride)!
        return ptr.bindMemory(to: T.self, capacity: max(1, count))
    }
    /// 段的字节数；写盘与建映射共用同一套算法，避免两边漂移。
    internal static func sectionSize(_ section: Section, _ capacities: Capacities) -> Int {
        switch section {
        case .nameOff: return (capacities.entries + 1) * 4
        case .parent, .sizeC, .mtime: return capacities.entries * 4
        case .flags, .depth, .kind: return capacities.entries
        case .names: return capacities.names
        case .altOff: return (capacities.alt + 1) * 4
        case .altOwner: return capacities.alt * 4
        case .altNames: return capacities.altNames
        case .table: return capacities.table * 4
        case .coverage: return capacities.coverage
        }
    }
    /// 每段按 4096 页对齐，mmap 才能把段指针直接交给读路径。
    internal static func fileLayout(rootLen: Int, capacities: Capacities) -> FileLayout {
        let page = 4096
        func align(_ value: Int) -> Int { (value + page - 1) & ~(page - 1) }
        var offsets: [Int] = [], sizes: [Int] = [], cursor = align(256 + rootLen)
        for section in Section.allCases {
            let size = sectionSize(section, capacities)
            offsets.append(cursor); sizes.append(size); cursor = align(cursor + size)
        }
        var total = align(256 + rootLen)
        for (index, size) in sizes.enumerated() where size > 0 { total = offsets[index] + size }
        return FileLayout(offsets: offsets, sizes: sizes, total: total)
    }
    internal var capacities: Capacities {
        Capacities(entries: capacity, names: namesCapacity, alt: altCapacity, altNames: altNamesCapacity, table: tableCapacity, coverage: 0)
    }
    init(rootPath: String, count: Int, namesLen: Int, altCount: Int, altLen: Int, fingerprint: UInt64, homeIndex: UInt32, finishedAt: UInt64, caseSensitiveNames: Bool = false, reserveExtra: Bool = true, backing: Backing = .fresh) {
        self.rootPath = rootPath; self.count = count; self.namesLen = namesLen; self.altCount = altCount; self.altLen = altLen
        var capacities: Capacities
        switch backing {
        case .fresh:
            let extra = reserveExtra ? min(count / 16, 16384) : 0
            let namesExtra = reserveExtra ? min(namesLen / 16, 65536) : 0
            let altExtra = reserveExtra ? min(altCount / 16, 16384) : 0
            let altNamesExtra = reserveExtra ? min(altLen / 16, 65536) : 0
            capacities = Capacities(entries: count + extra, names: namesLen + namesExtra, alt: altCount + altExtra, altNames: altLen + altNamesExtra)
        case .mapped(let mapped):
            capacities = mapped.capacities
        }
        self.capacity = capacities.entries; self.namesCapacity = capacities.names
        self.altCapacity = capacities.alt; self.altNamesCapacity = capacities.altNames
        self.configFingerprint = fingerprint; self.homeIndex = homeIndex; self.scanFinishedAt = finishedAt; self.liveCount = count
        self.caseSensitiveNames = caseSensitiveNames
        var owned: UInt16 = 0
        // 映射段直接指进文件；零长度段（没有备用名/没有哈希表）退化成 1 字节 malloc。
        func take<T>(_ type: T.Type, _ section: Section, _ elements: Int) -> UnsafeMutablePointer<T> {
            if case .mapped(let mapped) = backing, let pointer = mapped.pointer(type, section) { return pointer }
            owned |= 1 << section.rawValue
            return Self.alloc(type, elements)
        }
        nameOff = take(UInt32.self, .nameOff, capacity + 1); parent = take(UInt32.self, .parent, capacity)
        sizeC = take(UInt32.self, .sizeC, capacity); mtime = take(UInt32.self, .mtime, capacity)
        flags = take(UInt8.self, .flags, capacity); depth = take(UInt8.self, .depth, capacity); kind = take(UInt8.self, .kind, capacity)
        names = take(UInt8.self, .names, namesCapacity); altOff = take(UInt32.self, .altOff, altCapacity + 1)
        altOwner = take(UInt32.self, .altOwner, altCapacity); altNames = take(UInt8.self, .altNames, altNamesCapacity)
        table = capacities.table > 0 ? take(UInt32.self, .table, capacities.table) : nil
        self.ownedMask = owned
        if case .mapped(let mapped) = backing {
            self.mapping = mapped; self.tableCapacity = capacities.table
        }
        pthread_rwlock_init(&rwlock, nil)
    }
    deinit {
        releaseOwnedSections()
        pthread_rwlock_destroy(&rwlock)
    }
    /// 释放自己拥有的堆段并解映射；接管过映射的段不受影响（ownedMask 已清零）。
    private func releaseOwnedSections() {
        // free 之后这些页仍留在 malloc 的空闲链表里、照样算进 phys_footprint（实测数据见 MemoryReclaim.swift），
        // 所以先显式把页交还系统再 free：一次全盘重建就是几百 MB 的常驻内存差别。
        func release<T>(_ pointer: UnsafeMutablePointer<T>, _ section: Section, _ elements: Int) {
            guard ownedMask & (1 << section.rawValue) != 0 else { return }
            releasePagesToSystem(UnsafeMutableRawPointer(pointer), bytes: elements * MemoryLayout<T>.stride)
            free(pointer)
        }
        release(nameOff, .nameOff, capacity + 1); release(parent, .parent, capacity)
        release(sizeC, .sizeC, capacity); release(mtime, .mtime, capacity)
        release(flags, .flags, capacity); release(depth, .depth, capacity); release(kind, .kind, capacity)
        release(names, .names, namesCapacity)
        release(altOff, .altOff, altCapacity + 1); release(altOwner, .altOwner, altCapacity)
        release(altNames, .altNames, altNamesCapacity)
        if let table { release(table, .table, tableCapacity) }
        if let mapping { munmap(mapping.base, mapping.length) }
        ownedMask = 0; heapSections = 0; mapping = nil; table = nil
        tableCapacity = 0; tableUsed = 0
    }
    /// 真表示所有段都还在文件映射里：索引本身不占匿名内存，只有被改写过的页才计入。
    /// 任一段因扩容或写入被拷回堆（heapSections > 0）就不再是映射态，调用方需要重新落盘换回映射。
    public var isFileBacked: Bool { mapping != nil && heapSections == 0 }
    /// 当前映射到文件的字节数；非映射态为 0。这些页是干净的文件页，不计入 phys_footprint。
    public var mappedBytes: Int { mapping?.length ?? 0 }
    internal func mappedSectionBytes(_ section: Section) -> Int { mapping?.sizes[section.rawValue] ?? 0 }
    internal func ownsSection(_ section: Section) -> Bool { ownedMask & (1 << section.rawValue) != 0 }
    internal func takeOwnership(_ section: Section) { ownedMask |= 1 << section.rawValue }
    /// 落盘成功后原地接管刚写好的文件映射：对象身份与 version 不变，堆段归还系统，
    /// 索引页变回不计入物理内存的干净文件页。缓存与 UI 选择态因此全部保持有效。
    /// - Parameter other: 刚 load 出来、尚未发布给读者的 store；其映射被搬走后由本对象负责解映射。
    /// - Parameter expectedVersion: 快照时刻的版本；期间发生过写入就放弃接管（下次保存再试），
    ///   避免用旧快照覆盖新状态。
    /// - Parameter expectedMutations: 快照时刻的写入计数，与 expectedVersion 双重校验。
    /// - Returns: 真表示已接管。
    @discardableResult
    internal func adoptMapping(from other: IndexStore, expectedVersion: UInt64, expectedMutations: UInt64) -> Bool {
        guard other.mapping != nil else { return false }
        return write {
            guard version == expectedVersion, mutationCount == expectedMutations, let mapping = other.mapping else { return false }
            // 文件里没有哈希表时保留内存里已建好的表：数据没变，表仍然有效，不必接管后再重建。
            let keepTable = other.table == nil && ownsSection(.table) ? table : nil
            let keepCapacity = keepTable == nil ? 0 : tableCapacity
            let keepUsed = keepTable == nil ? 0 : tableUsed
            // 先摘掉表的所有权：releaseOwnedSections 按 ownedMask 释放，否则 free 的正是
            // 下面第 192 行要装回去的那块内存（读已释放内存 + double free）。
            if keepTable != nil { ownedMask &= ~(1 << Section.table.rawValue) }
            releaseOwnedSections()
            count = other.count; namesLen = other.namesLen; altCount = other.altCount; altLen = other.altLen
            capacity = other.capacity; namesCapacity = other.namesCapacity
            altCapacity = other.altCapacity; altNamesCapacity = other.altNamesCapacity
            configFingerprint = other.configFingerprint; scopeFingerprint = other.scopeFingerprint
            homeIndex = other.homeIndex; deletedCount = other.deletedCount; liveCount = other.liveCount
            version = other.version; lastEventId = other.lastEventId; scanFinishedAt = other.scanFinishedAt
            coverage = other.coverage; fsEventsUUID = other.fsEventsUUID
            tableCapacity = other.tableCapacity; tableUsed = other.tableUsed
            fullKey = other.fullKey; initialKey = other.initialKey
            nameOff = other.nameOff; parent = other.parent; sizeC = other.sizeC; mtime = other.mtime
            flags = other.flags; depth = other.depth; kind = other.kind; names = other.names
            altOff = other.altOff; altOwner = other.altOwner; altNames = other.altNames
            table = other.table
            ownedMask = other.ownedMask
            if let keepTable {
                table = keepTable; tableCapacity = keepCapacity; tableUsed = keepUsed
                ownedMask |= 1 << Section.table.rawValue
            }
            // 留下的表在堆上：只要还有堆段，就不是"整份由映射承载"。
            heapSections = keepTable == nil ? 0 : 1
            self.mapping = mapping
            // 映射与零长度段的 1 字节 malloc 都已转手，不能让 other 再释放一次。
            other.ownedMask = 0; other.mapping = nil; other.table = nil
            return true
        }
    }
    public func read<T>(_ body: () throws -> T) rethrows -> T { pthread_rwlock_rdlock(&rwlock); defer { pthread_rwlock_unlock(&rwlock) }; return try body() }
    public func write<T>(_ body: () throws -> T) rethrows -> T { pthread_rwlock_wrlock(&rwlock); defer { pthread_rwlock_unlock(&rwlock) }; return try body() }
    // Called only on a newly loaded store, before publishing it to readers.
    internal func rebase(to root: String) {
        let delta = root.split(separator: "/").count - rootPath.split(separator: "/").count
        if delta != 0 { for i in 0..<count { depth[i] = UInt8(clamping: Int(depth[i]) + delta) }; mutationCount &+= 1 }
        rootPath = root
    }
    public func nameBytes(_ i: UInt32) -> UnsafeBufferPointer<UInt8> {
        let n = Int(i); return UnsafeBufferPointer(start: names.advanced(by: Int(nameOff[n])), count: Int(nameOff[n+1] - nameOff[n]))
    }
    public func name(_ i: UInt32) -> String { String(decoding: nameBytes(i), as: UTF8.self) }
    public func path(_ i: UInt32) -> String {
        if i == 0 { return rootPath }
        var chain: [UInt32] = []; var e = i
        while e != 0 { chain.append(e); e = parent[Int(e)] }
        let root = rootPath == "/" ? "" : rootPath
        let length = root.utf8.count + chain.reduce(0) { $0 + 1 + Int(nameOff[Int($1)+1] - nameOff[Int($1)]) }
        return String(unsafeUninitializedCapacity: length) { out in
            var p = 0
            for b in root.utf8 { out[p] = b; p += 1 }
            for e in chain.reversed() { out[p] = 47; p += 1; for b in nameBytes(e) { out[p] = b; p += 1 } }
            return p
        }
    }
    public func parentPath(_ i: UInt32) -> String { path(parent[Int(i)]) }
    public static func encodeSize(_ size: UInt64) -> UInt32 { size < 0x80000000 ? UInt32(size) : 0x80000000 | UInt32(min(size >> 12, 0x7fffffff)) }
    public static func decodeSize(_ c: UInt32) -> UInt64 { c & 0x80000000 == 0 ? UInt64(c) : UInt64(c & 0x7fffffff) << 12 }
    public func size(_ i: UInt32) -> UInt64 { Self.decodeSize(sizeC[Int(i)]) }
    public func modified(_ i: UInt32) -> Date { Date(timeIntervalSince1970: TimeInterval(mtime[Int(i)])) }
    public func isLive(_ i: UInt32) -> Bool { flags[Int(i)] & SiftFlag.deleted == 0 }
    public var allocatedBytes: Int { (capacity + 1) * 4 + capacity * 4 * 3 + capacity * 3 + namesCapacity + (altCapacity + 1) * 4 + altCapacity * 4 + altNamesCapacity + tableCapacity * 4 }
}
