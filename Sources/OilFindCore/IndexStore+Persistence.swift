import Foundation
import Darwin
import COilFind

public enum IndexPersistenceError: Error { case noSpace, io(Int32) }
extension IndexStore {
    private var fileLength: Int {
        var length = 256 + rootPath.utf8.count + (count+1)*4 + count*4*3 + count*3 + namesLen + (altCount+1)*4 + altCount*4 + altLen
        if table != nil { length += tableCapacity * 4 }
        return length
    }
    public func save(to path: String) throws {
        try read { try saveLocked(to: path) }
    }
    /// 清掉崩溃残留的临时文件：保存写 `path.tmp.<pid>` 再 rename，进程被杀就留下整份残片。
    /// 只删 mtime 早于 `cutoff` 的（调用方传本次启动时刻），不碰其他进程正在写的临时文件。
    /// - Returns: 删除的文件数。
    @discardableResult
    public static func removeStaleTemporaryFiles(nextTo path: String, olderThan cutoff: Date) -> Int {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        let prefix = (path as NSString).lastPathComponent + ".tmp."
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return 0 }
        var removed = 0
        for name in names where name.hasPrefix(prefix) {
            let full = (dir as NSString).appendingPathComponent(name)
            guard let mtime = (try? fm.attributesOfItem(atPath: full))?[.modificationDate] as? Date, mtime < cutoff else { continue }
            if (try? fm.removeItem(atPath: full)) != nil { removed += 1 }
        }
        return removed
    }
    internal func saveSnapshot(to path: String) throws -> (version: UInt64, mutations: UInt64) {
        try read { try saveLocked(to: path); return (version, mutationCount) }
    }
    /// v4：每段按页对齐、按容量写盘，段之间的空隙留给文件系统当空洞。
    /// 这样 load 可以整份 mmap，索引页保持干净文件页，不进入物理内存统计。
    private func saveLocked(to path: String) throws {
        let coverageData = try JSONEncoder().encode(coverage)
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var capacities = self.capacities
        capacities.coverage = coverageData.count
        let layout = Self.fileLayout(rootLen: rootPath.utf8.count, capacities: capacities)
        // 页间空隙是文件空洞，不占磁盘；只有真正写进去的字节需要预留空间。
        let used = fileLength + coverageData.count
        var fs = statfs()
        if statfs(dir, &fs) != 0 { throw IndexPersistenceError.io(errno) }
        if UInt64(fs.f_bavail) * UInt64(fs.f_bsize) < UInt64(used) * 2 { throw IndexPersistenceError.noSpace }
        let tmp = path + ".tmp.\(getpid())"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        if fd < 0 { throw IndexPersistenceError.io(errno) }
        defer { close(fd); unlink(tmp) }
        func writeBytes(_ pointer: UnsafeRawPointer?, _ length: Int, at offset: Int) throws {
            guard length > 0, let pointer else { return }
            var done = 0
            while done < length {
                let n = pwrite(fd, pointer.advanced(by: done), length - done, off_t(offset + done))
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { throw IndexPersistenceError.io(errno) }
                done += n
            }
        }
        func writeSection<T>(_ pointer: UnsafeMutablePointer<T>, _ section: Section, _ elements: Int) throws {
            try writeBytes(pointer, elements * MemoryLayout<T>.stride, at: layout.offsets[section.rawValue])
        }
        var header = [UInt8](repeating: 0, count: 256)
        header.replaceSubrange(0..<8, with: Array("SIFTIDX\0".utf8))
        func put32(_ n: UInt32, _ pos: Int) { for i in 0..<4 { header[pos+i] = UInt8(truncatingIfNeeded: n >> (i*8)) } }
        func put64(_ n: UInt64, _ pos: Int) { for i in 0..<8 { header[pos+i] = UInt8(truncatingIfNeeded: n >> (i*8)) } }
        put32(4, 8); put32(UInt32(coverageData.count), 116); put32(UInt32(count), 12); put64(UInt64(namesLen), 16); put32(UInt32(altCount), 24); put32(UInt32(rootPath.utf8.count), 28)
        put64(UInt64(altLen), 32); put64(lastEventId, 40); put64(configFingerprint, 48); put64(scanFinishedAt, 56)
        for (i,b) in fsEventsUUID.utf8.prefix(40).enumerated() { header[64+i] = b }
        // 152：120 起 8 字节会被后面的容量字段覆盖，范围指纹必须放在容量字段之后。
        put64(scopeFingerprint, 152)
        put32(homeIndex, 104); put32(deletedCount, 108); header[112] = caseSensitiveNames ? 1 : 0
        put32(UInt32(capacity), 124); put32(UInt32(namesCapacity), 128); put32(UInt32(altCapacity), 132); put32(UInt32(altNamesCapacity), 136)
        put32(UInt32(tableCapacity), 140); put64(version, 144)
        try header.withUnsafeBytes { try writeBytes($0.baseAddress, 256, at: 0) }
        let root = Array(rootPath.utf8)
        try root.withUnsafeBytes { try writeBytes($0.baseAddress, root.count, at: 256) }
        try writeSection(nameOff, .nameOff, count + 1); try writeSection(parent, .parent, count)
        try writeSection(sizeC, .sizeC, count); try writeSection(mtime, .mtime, count)
        try writeSection(flags, .flags, count); try writeSection(depth, .depth, count); try writeSection(kind, .kind, count)
        try writeSection(names, .names, namesLen)
        try writeSection(altOff, .altOff, altCount + 1); try writeSection(altOwner, .altOwner, altCount); try writeSection(altNames, .altNames, altLen)
        if let table, tableCapacity > 0 { try writeSection(table, .table, tableCapacity) }
        try coverageData.withUnsafeBytes { try writeBytes($0.baseAddress, $0.count, at: layout.offsets[Section.coverage.rawValue]) }
        if fsync(fd) != 0 { throw IndexPersistenceError.io(errno) }
        if rename(tmp, path) != 0 { throw IndexPersistenceError.io(errno) }
    }
    public static func load(from path: String) -> IndexStore? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size >= 256 else { return nil }
        var header = [UInt8](repeating: 0, count: 256)
        let read = header.withUnsafeMutableBytes { pread(fd, $0.baseAddress, 256, 0) }
        guard read == 256, header[0..<8].elementsEqual(Array("SIFTIDX\0".utf8)) else { return nil }
        func u32(_ at: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(header[at+$1]) << ($1*8) } }
        func u64(_ at: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(header[at+$1]) << ($1*8) } }
        guard u32(8) == 4 else { return loadLegacy(from: path) }
        guard header[112] <= 1 else { return nil }
        guard let count = Int(exactly: u32(12)), count > 0, count <= 20_000_000,
              let namesLen = Int(exactly: u64(16)), namesLen <= Int(UInt32.max),
              let altCount = Int(exactly: u32(24)), altCount <= 40_000_000,
              let rootLen = Int(exactly: u32(28)), rootLen < 4096,
              let altLen = Int(exactly: u64(32)), altLen <= Int(UInt32.max) else { return nil }
        let capacities = Capacities(entries: Int(u32(124)), names: Int(u32(128)), alt: Int(u32(132)), altNames: Int(u32(136)), table: Int(u32(140)), coverage: Int(u32(116)))
        guard capacities.entries >= count, capacities.entries <= 40_000_000,
              capacities.names >= namesLen, capacities.alt >= altCount, capacities.altNames >= altLen,
              capacities.coverage <= 200_000, capacities.table <= 40_000_000,
              capacities.table == 0 || capacities.table >= count else { return nil }
        let layout = fileLayout(rootLen: rootLen, capacities: capacities)
        guard layout.total == Int(info.st_size) else { return nil }
        guard let base = mmap(nil, layout.total, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, 0), base != MAP_FAILED else { return nil }
        let mapping = IndexFileMapping(base: base, length: layout.total, offsets: layout.offsets, sizes: layout.sizes, capacities: capacities)
        let root = String(decoding: UnsafeRawBufferPointer(start: base.advanced(by: 256), count: rootLen), as: UTF8.self)
        let s = IndexStore(rootPath: root, count: count, namesLen: namesLen, altCount: altCount, altLen: altLen, fingerprint: u64(48), homeIndex: u32(104), finishedAt: u64(56), caseSensitiveNames: header[112] == 1, reserveExtra: false, backing: .mapped(mapping))
        guard sift_validate_index(s.nameOff, s.parent, s.kind, count, namesLen, s.altOff, s.altOwner, altCount, altLen, s.homeIndex, u32(108)) != 0 else { return nil }
        if capacities.table > 0, let table = s.table {
            // 位图查重：只数「非空槽数」会放过重复槽（被重复指向的那个索引查得到，另一个条目永远查不到），
            // 那正是「宁可慢也不给错答案」要挡的错答案。count 位，40M 条目约 5MB 临时内存。
            let bytes = max(1, (count + 7) / 8)
            let seen = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 1)
            defer { seen.deallocate() }
            memset(seen, 0, bytes)
            let bits = seen.assumingMemoryBound(to: UInt8.self)
            var used = 0, consistent = true
            for slot in 0..<capacities.table {
                let value = table[slot]
                if value == UInt32.max { continue }
                if Int(value) >= count { consistent = false; break }
                let index = Int(value)
                if bits[index >> 3] & (1 << UInt8(index & 7)) != 0 { consistent = false; break }
                bits[index >> 3] |= 1 << UInt8(index & 7)
                used += 1
            }
            // 哈希表与条目数不一致（含重复槽）时丢弃映射表，交给调用方重建，宁可慢也不给错答案。
            if consistent && used == count { s.tableUsed = used } else { s.table = nil; s.tableCapacity = 0 }
        }
        if capacities.coverage > 0 {
            let start = layout.offsets[Section.coverage.rawValue]
            let data = Data(bytes: base.advanced(by: start), count: capacities.coverage)
            // 统计段只服务诊断：解码不了就退回空统计，不为一份统计丢掉整库（结构由 sift_validate_index 把关）。
            if let coverage = try? JSONDecoder().decode(CoverageStats.self, from: data),
               coverage.buckets.values.allSatisfy({ $0.examples.count <= 5 && $0.examples.allSatisfy { $0.utf8.count <= 4096 } }) {
                s.coverage = coverage
            }
        }
        s.scopeFingerprint = u64(152)
        s.version = u64(144)
        s.lastEventId = u64(40); s.deletedCount = u32(108); s.liveCount = count - Int(u32(108))
        s.fsEventsUUID = String(decoding: UnsafeRawBufferPointer(start: base.advanced(by: 64), count: 40).prefix(while: { $0 != 0 }), as: UTF8.self)
        return s
    }
    /// v2/v3：段紧凑排列、载入即 memcpy 进 malloc，仅用于兼容旧文件（首次保存后自动升级为 v4）。
    private static func loadLegacy(from path: String) -> IndexStore? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe), data.count >= 256 else { return nil }
        return data.withUnsafeBytes { raw -> IndexStore? in
            let p = raw.bindMemory(to: UInt8.self)
            guard p.prefix(8).elementsEqual(Array("SIFTIDX\0".utf8)) else { return nil }
            func u32(_ at: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(p[at+$1]) << ($1*8) } }
            func u64(_ at: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(p[at+$1]) << ($1*8) } }
            guard (u32(8) == 2 || u32(8) == 3), p[112] <= 1 else { return nil }
            guard let count = Int(exactly: u32(12)),
                  let namesLen = Int(exactly: u64(16)),
                  let altCount = Int(exactly: u32(24)),
                  let rootLen = Int(exactly: u32(28)),
                  let altLen = Int(exactly: u64(32)) else { return nil }
            guard count > 0, count <= 20_000_000, rootLen < 4096, altCount <= 40_000_000,
                  namesLen <= Int(UInt32.max), altLen <= Int(UInt32.max) else { return nil }
            func multiplied(_ lhs: Int, _ rhs: Int) -> Int? {
                let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
                return overflow ? nil : value
            }
            var expected = 256
            func addExpected(_ value: Int) -> Bool {
                let (sum, overflow) = expected.addingReportingOverflow(value)
                guard !overflow else { return false }
                expected = sum
                return true
            }
            guard let nameOffBytes = multiplied(count + 1, 4),
                  let entryWordBytes = multiplied(count, 12),
                  let entryFlagBytes = multiplied(count, 3),
                  let altOffBytes = multiplied(altCount + 1, 4),
                  let altOwnerBytes = multiplied(altCount, 4),
                  addExpected(rootLen), addExpected(nameOffBytes), addExpected(entryWordBytes),
                  addExpected(entryFlagBytes), addExpected(namesLen), addExpected(altOffBytes),
                  addExpected(altOwnerBytes), addExpected(altLen) else { return nil }
            let coverageLength = u32(8) == 3 ? Int(u32(116)) : 0
            guard coverageLength <= 200_000, addExpected(coverageLength) else { return nil }
            guard expected == data.count else { return nil }
            var pos = 256
            let root = String(decoding: p[pos..<(pos+rootLen)], as: UTF8.self); pos += rootLen
            let homeIndex = u32(104), deletedCount = u32(108)
            let caseSensitiveNames = p[112] == 1
            let s = IndexStore(rootPath: root, count: count, namesLen: namesLen, altCount: altCount, altLen: altLen, fingerprint: u64(48), homeIndex: homeIndex, finishedAt: u64(56), caseSensitiveNames: caseSensitiveNames, reserveExtra: false)
            func copy(_ dst: UnsafeMutableRawPointer, _ n: Int) { if n > 0 { memcpy(dst, p.baseAddress!.advanced(by: pos), n) }; pos += n }
            copy(s.nameOff, (count+1)*4); copy(s.parent, count*4); copy(s.sizeC, count*4); copy(s.mtime, count*4)
            copy(s.flags, count); copy(s.depth, count); copy(s.kind, count); copy(s.names, namesLen)
            copy(s.altOff, (altCount+1)*4); copy(s.altOwner, altCount*4); copy(s.altNames, altLen)
            if coverageLength > 0 {
                let data = Data(p[pos..<(pos + coverageLength)])
                if let coverage = try? JSONDecoder().decode(CoverageStats.self, from: data),
                   coverage.buckets.values.allSatisfy({ $0.examples.count <= 5 && $0.examples.allSatisfy { $0.utf8.count <= 4096 } }) {
                    s.coverage = coverage
                }
            }
            guard sift_validate_index(s.nameOff, s.parent, s.kind, count, namesLen, s.altOff, s.altOwner, altCount, altLen, homeIndex, deletedCount) != 0 else { return nil }
            s.scopeFingerprint = u64(120)
            s.lastEventId = u64(40); s.deletedCount = deletedCount; s.liveCount = count - Int(deletedCount)
            s.fsEventsUUID = String(decoding: p[64..<104].prefix(while: { $0 != 0 }), as: UTF8.self)
            return s
        }
    }
}
