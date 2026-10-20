import XCTest
import Foundation
@testable import OilFindCore

final class M7StorageTests: XCTestCase {
    private func withTempDirectory(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OilFindM7-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    private func packageFlags(_ name: String, type: UInt32 = 1) -> UInt8 {
        let bytes = Array(name.utf8)
        return bytes.withUnsafeBufferPointer { Classifier.flags(name: $0, type: type, bsdFlags: 0, inherited: 0) }
    }

    private func emptyStore(caseSensitive: Bool) -> IndexStore {
        let store = IndexStore(rootPath: "/", count: 1, namesLen: 0, altCount: 0, altLen: 0,
                               fingerprint: 0, homeIndex: .max, finishedAt: 0,
                               caseSensitiveNames: caseSensitive)
        store.nameOff[0] = 0; store.nameOff[1] = 0; store.parent[0] = 0
        store.sizeC[0] = 0; store.mtime[0] = 0; store.flags[0] = SiftFlag.dir
        store.depth[0] = 0; store.kind[0] = 1; store.altOff[0] = 0
        store.buildHash()
        return store
    }

    private func persistenceStore(caseSensitiveNames: Bool = false) -> IndexStore {
        let store = IndexStore(rootPath: "/", count: 3, namesLen: 2, altCount: 2, altLen: 2,
                               fingerprint: 17, homeIndex: 1, finishedAt: 123, caseSensitiveNames: caseSensitiveNames)
        store.nameOff[0] = 0; store.nameOff[1] = 0; store.nameOff[2] = 1; store.nameOff[3] = 2
        store.parent[0] = 0; store.parent[1] = 0; store.parent[2] = 0
        store.sizeC[0] = 0; store.sizeC[1] = 1; store.sizeC[2] = 2
        store.mtime[0] = 0; store.mtime[1] = 1; store.mtime[2] = 2
        store.flags[0] = SiftFlag.dir; store.flags[1] = SiftFlag.dir; store.flags[2] = 0
        store.depth[0] = 0; store.depth[1] = 1; store.depth[2] = 1
        store.kind[0] = 1; store.kind[1] = 1; store.kind[2] = 0
        store.names[0] = 120; store.names[1] = 121
        store.altOff[0] = 0; store.altOff[1] = 1; store.altOff[2] = 2
        store.altOwner[0] = 1; store.altOwner[1] = 2
        store.altNames[0] = 97; store.altNames[1] = 98
        return store
    }

    private func put32(_ value: UInt32, at offset: Int, in data: inout Data) {
        for byte in 0..<4 { data[offset + byte] = UInt8(truncatingIfNeeded: value >> (byte * 8)) }
    }

    private func put64(_ value: UInt64, at offset: Int, in data: inout Data) {
        for byte in 0..<8 { data[offset + byte] = UInt8(truncatingIfNeeded: value >> (byte * 8)) }
    }

    func testT71PersistenceRejectsMalformedStructure() throws {
        try withTempDirectory { directory in
            let url = directory.appendingPathComponent("valid.idx")
            let store = persistenceStore()
            try store.save(to: url.path)
            let original = try Data(contentsOf: url)
            XCTAssertEqual(original[8], 4)
            XCTAssertNotNil(IndexStore.load(from: url.path))

            let count = 3, altCount = 2
            // v4 每段按页对齐，偏移由同一套布局算法给出，测试直接复用避免写死魔数。
            let layout = IndexStore.fileLayout(rootLen: 1, capacities: IndexStore.Capacities(entries: count, names: 2, alt: altCount, altNames: 2, table: 0, coverage: 0))
            func sectionStart(_ section: IndexStore.Section) -> Int { layout.offsets[section.rawValue] }
            let nameOffStart = sectionStart(.nameOff)
            let parentStart = sectionStart(.parent)
            let kindStart = sectionStart(.kind)
            let altOffStart = sectionStart(.altOff)
            let altOwnerStart = sectionStart(.altOwner)

            func rejects(_ label: String, _ mutate: (inout Data) -> Void, file: StaticString = #filePath, line: UInt = #line) throws {
                var damaged = original
                mutate(&damaged)
                try damaged.write(to: url)
                XCTAssertNil(IndexStore.load(from: url.path), label, file: file, line: line)
            }

            try rejects("nameOff[0] must be zero") { data in self.put32(1, at: nameOffStart, in: &data) }
            try rejects("nameOff must be monotone") { data in
                self.put32(1, at: nameOffStart + 4, in: &data)
                self.put32(0, at: nameOffStart + 2 * 4, in: &data)
            }
            try rejects("parent[0] must be zero") { data in self.put32(1, at: parentStart, in: &data) }
            try rejects("each non-root parent must precede its child") { data in self.put32(1, at: parentStart + 4, in: &data) }
            try rejects("parent[1] must not be UInt32.max") { data in self.put32(UInt32.max, at: parentStart + 4, in: &data) }
            try rejects("altOff[0] must be zero") { data in self.put32(1, at: altOffStart, in: &data) }
            try rejects("altOff must be monotone") { data in self.put32(3, at: altOffStart + 4, in: &data) }
            try rejects("altOwner must be within count") { data in self.put32(3, at: altOwnerStart, in: &data) }
            try rejects("altOwner must be monotone") { data in
                self.put32(2, at: altOwnerStart, in: &data); self.put32(1, at: altOwnerStart + 4, in: &data)
            }
            try rejects("homeIndex must be valid") { data in self.put32(3, at: 104, in: &data) }
            try rejects("deletedCount must not exceed count") { data in self.put32(4, at: 108, in: &data) }
            try rejects("kind must be in the supported range") { data in data[kindStart + 2] = 9 }
            try rejects("case sensitivity byte must be 0 or 1") { data in data[112] = 2 }
            try rejects("name length must convert to Int safely") { data in self.put64(UInt64.max, at: 16, in: &data) }
            try rejects("alternate name length must convert to Int safely") { data in self.put64(UInt64.max, at: 32, in: &data) }
            try rejects("format version 1 must be rebuilt") { data in self.put32(1, at: 8, in: &data) }
        }
    }

    func testV4MappedStoreRoundTripAndGrowth() throws {
        try withTempDirectory { directory in
            let url = directory.appendingPathComponent("mapped.idx")
            let store = persistenceStore()
            store.buildHash()
            try store.save(to: url.path)

            let loaded = try XCTUnwrap(IndexStore.load(from: url.path))
            XCTAssertTrue(loaded.isFileBacked)
            XCTAssertTrue(loaded.hashReady)
            XCTAssertEqual(loaded.count, 3)
            XCTAssertEqual(loaded.capacity, 3)
            XCTAssertEqual(loaded.name(1), "x")
            XCTAssertEqual(loaded.resolve(path: "/x"), 1)
            XCTAssertEqual(loaded.version, 0)

            // 映射段不可 realloc：首次扩容要拷到堆上，且旧数据必须完整。
            var inserted: UInt32 = 0
            loaded.write { Array("z".utf8).withUnsafeBufferPointer { inserted = loaded.insert(parent: 0, name: $0, attrs: EntryAttrs(type: 0)) } }
            XCTAssertEqual(inserted, 3)
            XCTAssertEqual(loaded.count, 4)
            XCTAssertEqual(loaded.name(3), "z")
            XCTAssertEqual(loaded.name(1), "x")
            XCTAssertEqual(loaded.resolve(path: "/x"), 1)
            XCTAssertEqual(loaded.resolve(path: "/z"), 3)
            XCTAssertTrue(loaded.ownsSection(.nameOff))
            // 没被改写的段仍留在映射里，只有扩容过的段才拷到堆上。
            XCTAssertFalse(loaded.ownsSection(.altNames))
            XCTAssertFalse(loaded.ownsSection(.altOff))

            // 改写过之后仍能落盘再读回，容量与内容都不丢。
            try loaded.save(to: url.path)
            let reloaded = try XCTUnwrap(IndexStore.load(from: url.path))
            XCTAssertTrue(reloaded.isFileBacked)
            XCTAssertEqual(reloaded.count, 4)
            XCTAssertEqual(reloaded.name(3), "z")
            XCTAssertEqual(reloaded.resolve(path: "/z"), 3)
        }
    }

    func testV4HeaderFieldsRoundTripAndAdoption() throws {
        try withTempDirectory { directory in
            let url = directory.appendingPathComponent("header.idx")
            let store = persistenceStore(caseSensitiveNames: true)
            store.scopeFingerprint = 0xABCDEF01_23456789
            store.version = 99; store.lastEventId = 1234; store.fsEventsUUID = "UUID-1234"
            store.deletedCount = 1; store.liveCount = 2
            store.buildHash()
            try store.save(to: url.path)

            let loaded = try XCTUnwrap(IndexStore.load(from: url.path))
            XCTAssertEqual(loaded.scopeFingerprint, 0xABCDEF01_23456789)
            XCTAssertEqual(loaded.configFingerprint, 17)
            XCTAssertEqual(loaded.version, 99)
            XCTAssertEqual(loaded.lastEventId, 1234)
            XCTAssertEqual(loaded.scanFinishedAt, 123)
            XCTAssertEqual(loaded.fsEventsUUID, "UUID-1234")
            XCTAssertEqual(loaded.homeIndex, 1)
            XCTAssertEqual(loaded.deletedCount, 1)
            XCTAssertEqual(loaded.liveCount, 2)
            XCTAssertTrue(loaded.caseSensitiveNames)

            // 落盘后原地接管：对象身份不变，所有段回到映射，堆段交还系统。
            XCTAssertFalse(store.isFileBacked)
            XCTAssertTrue(store.adoptMapping(from: loaded, expectedVersion: 99, expectedMutations: 0))
            XCTAssertTrue(store.isFileBacked)
            XCTAssertFalse(loaded.isFileBacked)
            XCTAssertEqual(store.count, 3)
            XCTAssertFalse(store.ownsSection(.nameOff))
            XCTAssertFalse(store.ownsSection(.names))
            XCTAssertFalse(store.ownsSection(.table))
            XCTAssertTrue(store.read { store.hashReady })
            XCTAssertEqual(store.name(1), "x")
            XCTAssertEqual(store.resolve(path: "/x"), 1)

            // 写入计数是第二重见证：版本没变但数据被写过（调用方漏掉 version 自增）时同样拒绝接管。
            let snapshotMutations = store.read { store.mutationCount }
            store.write { Array("zz".utf8).withUnsafeBufferPointer { _ = store.insert(parent: 0, name: $0, attrs: EntryAttrs(type: 0)) } }
            XCTAssertEqual(store.mutationCount, snapshotMutations + 1)
            XCTAssertFalse(store.isFileBacked)
            let stale = try XCTUnwrap(IndexStore.load(from: url.path))
            XCTAssertFalse(store.adoptMapping(from: stale, expectedVersion: 99, expectedMutations: snapshotMutations))
            XCTAssertNotNil(store.resolve(path: "/zz"))
            XCTAssertTrue(stale.isFileBacked)

            // 快照之后又写过（版本已变）就拒绝接管：不能用旧快照覆盖新状态，
            // 被拒绝的一方也必须完好无损，仍可继续用。
            store.version = 100
            let other = try XCTUnwrap(IndexStore.load(from: url.path))
            XCTAssertFalse(store.adoptMapping(from: other, expectedVersion: 99, expectedMutations: store.read { store.mutationCount }))
            // 拒绝接管后双方都完好：自己的新写入还在，对方仍是干净的映射态。
            XCTAssertFalse(store.isFileBacked)
            XCTAssertNotNil(store.resolve(path: "/zz"))
            XCTAssertTrue(other.isFileBacked)
            XCTAssertEqual(other.resolve(path: "/x"), 1)
        }
    }

    func testV3FileStillLoadsAndUpgradesToMapped() throws {
        try withTempDirectory { directory in
            let url = directory.appendingPathComponent("legacy.idx")
            let store = persistenceStore()
            store.buildHash()
            try writeLegacyV3File(store, to: url)

            let legacy = try XCTUnwrap(IndexStore.load(from: url.path))
            XCTAssertFalse(legacy.isFileBacked)
            XCTAssertEqual(legacy.count, 3)
            XCTAssertEqual(legacy.name(1), "x")
            // v3 不存哈希表：载入后由调用方补建，这里显式补上再按路径查询。
            XCTAssertNil(legacy.table)
            legacy.write { legacy.buildHash() }
            XCTAssertEqual(legacy.resolve(path: "/x"), 1)

            try legacy.save(to: url.path)
            let upgraded = try XCTUnwrap(IndexStore.load(from: url.path))
            XCTAssertTrue(upgraded.isFileBacked)
            XCTAssertTrue(upgraded.hashReady)
            XCTAssertEqual(upgraded.count, 3)
            XCTAssertEqual(upgraded.resolve(path: "/x"), 1)
        }
    }

    func testT76PackageExtensionsUseFullCaseFoldedBytes() {
        for ext in Classifier.packages {
            XCTAssertNotEqual(packageFlags("folder.\(ext)") & SiftFlag.package, 0, ext)
        }
        for ext in ["ramework", "enstudio", "app2", "ap"] {
            XCTAssertEqual(packageFlags("folder.\(ext)") & SiftFlag.package, 0, ext)
        }
        XCTAssertNotEqual(packageFlags("folder.FrameWork") & SiftFlag.package, 0)
        XCTAssertEqual(packageFlags("folder.app", type: 0) & SiftFlag.package, 0)
        for ext in ["pages", "numbers", "key"] {
            XCTAssertNotEqual(packageFlags("folder.\(ext)", type: 1) & SiftFlag.package, 0)
            XCTAssertEqual(packageFlags("file.\(ext)", type: 0) & SiftFlag.package, 0)
        }
        let appName = Array("Example.APP".utf8)
        let appFlags = appName.withUnsafeBufferPointer { Classifier.flags(name: $0, type: 1, bsdFlags: 0, inherited: 0) }
        XCTAssertEqual(appName.withUnsafeBufferPointer { Classifier.kind(name: $0, flags: appFlags) }, 2)
    }

    func testT78CaseSensitiveLookupAndPersistence() throws {
        let sensitive = emptyStore(caseSensitive: true)
        var lower: UInt32 = 0, upper: UInt32 = 0
        Array("a.txt".utf8).withUnsafeBufferPointer { lower = sensitive.insert(parent: 0, name: $0, attrs: EntryAttrs(type: 0)) }
        Array("A.txt".utf8).withUnsafeBufferPointer { upper = sensitive.insert(parent: 0, name: $0, attrs: EntryAttrs(type: 0)) }
        XCTAssertNotEqual(lower, upper)
        XCTAssertEqual(sensitive.resolve(path: "/a.txt"), lower)
        XCTAssertEqual(sensitive.resolve(path: "/A.txt"), upper)
        sensitive.write { _ = sensitive.remove(lower); sensitive.sweep() }
        XCTAssertNil(sensitive.resolve(path: "/a.txt"))
        XCTAssertEqual(sensitive.resolve(path: "/A.txt"), upper)

        let insensitive = emptyStore(caseSensitive: false)
        var existing: UInt32 = 0
        Array("a.txt".utf8).withUnsafeBufferPointer { existing = insensitive.insert(parent: 0, name: $0, attrs: EntryAttrs(type: 0)) }
        XCTAssertEqual(insensitive.resolve(path: "/A.txt"), existing)

        try withTempDirectory { directory in
            let url = directory.appendingPathComponent("sensitive.idx")
            try sensitive.save(to: url.path)
            let bytes = try Data(contentsOf: url)
            XCTAssertEqual(bytes[112], 1)
            XCTAssertEqual(try XCTUnwrap(IndexStore.load(from: url.path)).caseSensitiveNames, true)
        }
    }

    /// 回归（对抗式审查 r1-F1/r3-F1）：接管时若文件没有可用哈希表，自有堆表要留下并重新登记所有权。
    /// 修复前 releaseOwnedSections 会把这张表 free 掉，随后又把悬垂指针装回 table → 读已释放内存 + double free。
    func testAdoptionKeepsOwnHeapTableAlive() throws {
        try withTempDirectory { directory in
            let url = directory.appendingPathComponent("noTable.idx")
            // 内容完全相同的孪生索引，但不建哈希表 → 落盘的文件没有表段。
            let twin = persistenceStore()
            try twin.save(to: url.path)
            let tableless = try XCTUnwrap(IndexStore.load(from: url.path))
            XCTAssertNil(tableless.table)
            XCTAssertEqual(tableless.count, 3)

            let owner = persistenceStore()
            owner.buildHash()
            XCTAssertNotNil(owner.table)
            XCTAssertTrue(owner.ownsSection(.table))

            XCTAssertTrue(owner.adoptMapping(from: tableless, expectedVersion: owner.version, expectedMutations: owner.mutationCount))
            // 表还在堆上，就不能谎报「整份由映射承载」。
            XCTAssertFalse(owner.isFileBacked)
            XCTAssertTrue(owner.hashReady)
            XCTAssertTrue(owner.ownsSection(.table))
            XCTAssertEqual(owner.resolve(path: "/x"), 1)

            // 留下的表必须仍是有效内存：落盘会把整表读一遍，读到已释放内存这里就会暴露。
            try owner.save(to: url.path)
            let roundTrip = try XCTUnwrap(IndexStore.load(from: url.path))
            XCTAssertEqual(roundTrip.count, 3)
            XCTAssertTrue(roundTrip.hashReady)
            XCTAssertEqual(roundTrip.resolve(path: "/x"), 1)
        }
    }

    /// 回归（对抗式审查 r3-F2）：表里有重复槽时整表作废重建，不能让部分条目静默查不到。
    func testDuplicateTableSlotRejectsTable() throws {
        try withTempDirectory { directory in
            let url = directory.appendingPathComponent("dupTable.idx")
            let store = persistenceStore()
            store.buildHash()
            try store.save(to: url.path)
            XCTAssertNotNil(try XCTUnwrap(IndexStore.load(from: url.path)).table)

            let capacities = store.capacities
            let tableOffset = IndexStore.fileLayout(rootLen: store.rootPath.utf8.count, capacities: capacities).offsets[IndexStore.Section.table.rawValue]
            var data = try Data(contentsOf: url)
            func slot(_ index: Int) -> UInt32 {
                (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[tableOffset + index * 4 + $1]) << UInt32($1 * 8) }
            }
            // 找出前两个非空槽，把第二个改成与第一个重复 → 必有一个条目再也查不到。
            var filled: [Int] = []
            for index in 0..<capacities.table where slot(index) != UInt32.max {
                filled.append(index)
                if filled.count == 2 { break }
            }
            XCTAssertEqual(filled.count, 2)
            put32(slot(filled[0]), at: tableOffset + filled[1] * 4, in: &data)
            try data.write(to: url)

            let loaded = try XCTUnwrap(IndexStore.load(from: url.path))
            XCTAssertNil(loaded.table)
            XCTAssertEqual(loaded.count, 3)
            loaded.write { loaded.buildHash() }
            XCTAssertEqual(loaded.resolve(path: "/x"), 1)
        }
    }

    /// 回归（对抗式审查 r3-F3）：崩溃残留的临时文件要清掉，别的进程正在写的和无关文件不能碰。
    func testStaleTemporaryFilesRemovedButActiveKept() throws {
        try withTempDirectory { directory in
            let db = directory.appendingPathComponent("index.db")
            let stale = directory.appendingPathComponent("index.db.tmp.999")
            let active = directory.appendingPathComponent("index.db.tmp.123")
            let unrelated = directory.appendingPathComponent("other.db.tmp.1")
            for path in [db.path, stale.path, active.path, unrelated.path] { try Data("x".utf8).write(to: URL(fileURLWithPath: path)) }
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: stale.path)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 300)], ofItemAtPath: active.path)

            XCTAssertEqual(IndexStore.removeStaleTemporaryFiles(nextTo: db.path, olderThan: Date()), 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: db.path))
        }
    }

    /// 回归（对抗式审查 r3-F4）：统计段坏了只丢统计，不能整库拒绝（否则每次启动全量重扫）。
    func testCorruptCoverageStillLoadsIndex() throws {
        try withTempDirectory { directory in
            let url = directory.appendingPathComponent("coverage.idx")
            let store = persistenceStore()
            store.buildHash()
            var stats = store.coverage
            stats.buckets[.fileType] = CoverageBucket(count: 7, examples: ["/x"])
            store.coverage = stats
            try store.save(to: url.path)

            // 统计段是最后一段：打坏文件末尾 3 字节，结构段完好。
            var data = try Data(contentsOf: url)
            for offset in 1...3 { data[data.count - offset] = 0xFF }
            try data.write(to: url)

            let loaded = try XCTUnwrap(IndexStore.load(from: url.path))
            XCTAssertEqual(loaded.count, 3)
            XCTAssertEqual(loaded.name(1), "x")
            XCTAssertTrue(loaded.coverage.buckets.isEmpty)
        }
    }

    func testT80ScannerCancellationIsStickyAndResponsive() throws {
        try skipIfCI("Scanner cancellation responsiveness depends on host scheduling.")
        try withTempDirectory { root in
            var config = IndexConfig.standard()
            config.rootPath = root.path
            config.indexSystemDirs = true
            let preCancelled = Scanner(config: config, threads: 2)
            preCancelled.cancel()
            XCTAssertNil(preCancelled.run())
            XCTAssertNil(preCancelled.run())

            let fm = FileManager.default
            for directory in 0..<80 {
                let folder = root.appendingPathComponent("d\(directory)")
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                for file in 0..<80 {
                    try Data().write(to: folder.appendingPathComponent("f\(file).txt"))
                }
            }
            let scanner = Scanner(config: config, threads: 2)
            let done = DispatchSemaphore(value: 0)
            let resultLock = NSLock()
            var result: ScanOutput?
            DispatchQueue.global().async {
                let output = scanner.run()
                resultLock.lock(); result = output; resultLock.unlock()
                done.signal()
            }
            let progressDeadline = Date().addingTimeInterval(2)
            while scanner.scannedCount <= 1 && Date() < progressDeadline { Thread.sleep(forTimeInterval: 0.002) }
            XCTAssertGreaterThan(scanner.scannedCount, 1, "scanner should have started reading batches")
            scanner.cancel()
            XCTAssertEqual(done.wait(timeout: .now() + 1), .success, "cancelled scan should finish within one second")
            resultLock.lock(); let output = result; resultLock.unlock()
            XCTAssertNil(output)
            XCTAssertNil(scanner.run(), "a Scanner instance may run only once")
        }
    }

    func testT81ScannerDoesNotFollowSymlinkDirectories() throws {
        try withTempDirectory { container in
            let ancestor = container.appendingPathComponent("ancestor")
            let root = ancestor.appendingPathComponent("root")
            let outside = container.appendingPathComponent("outside")
            let fm = FileManager.default
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try fm.createDirectory(at: outside, withIntermediateDirectories: true)
            try Data("ancestor".utf8).write(to: ancestor.appendingPathComponent("ancestor-only.txt"))
            try Data("outside".utf8).write(to: outside.appendingPathComponent("outside-only.txt"))
            var config = IndexConfig.standard()
            config.rootPath = root.path
            config.indexSystemDirs = true
            let initialOutput = try XCTUnwrap(Scanner(config: config, threads: 2).run())
            let indexed = IndexStore(scan: initialOutput, config: config)
            indexed.write { indexed.buildHash() }

            let added = root.appendingPathComponent("newdir")
            try fm.createDirectory(at: added, withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: added.appendingPathComponent("outside-link").path, withDestinationPath: outside.path)
            try fm.createSymbolicLink(atPath: added.appendingPathComponent("ancestor-link").path, withDestinationPath: ancestor.path)
            _ = IndexUpdater(config: config).apply([FSChange(path: added.path, eventId: 1)], to: indexed)

            let scanner = Scanner(config: config, threads: 2)
            let output = try XCTUnwrap(scanner.run())
            let fullScan = IndexStore(scan: output, config: config)
            let paths = (0..<indexed.count).map { indexed.path(UInt32($0)) }
            let expected = (0..<fullScan.count).map { fullScan.path(UInt32($0)) }
            XCTAssertEqual(Set(paths), Set(expected), "subtree update must match a full scan")
            XCTAssertTrue(paths.contains(added.path + "/outside-link"))
            XCTAssertTrue(paths.contains(added.path + "/ancestor-link"))
            XCTAssertFalse(paths.contains { $0.hasPrefix(added.path + "/outside-link/") })
            XCTAssertFalse(paths.contains { $0.hasPrefix(added.path + "/ancestor-link/") })
            XCTAssertFalse(paths.contains { $0.hasSuffix("outside-only.txt") })
            XCTAssertFalse(paths.contains { $0.hasSuffix("ancestor-only.txt") })
            XCTAssertNil(scanner.run(), "a Scanner instance may run only once")
        }
    }

    func testT81ScannerRejectsSymlinkedIntermediateAncestor() throws {
        try withTempDirectory { container in
            let root = container.appendingPathComponent("root")
            let originalParent = root.appendingPathComponent("replace")
            let originalChild = originalParent.appendingPathComponent("child")
            let movedParent = container.appendingPathComponent("moved-replace")
            let external = container.appendingPathComponent("external")
            let targetChild = external.appendingPathComponent("child")
            let fm = FileManager.default
            try fm.createDirectory(at: originalChild, withIntermediateDirectories: true)
            try fm.createDirectory(at: targetChild, withIntermediateDirectories: true)
            try Data("original".utf8).write(to: originalChild.appendingPathComponent("original-only.txt"))
            try Data("external".utf8).write(to: targetChild.appendingPathComponent("external-only.txt"))

            var config = IndexConfig.standard()
            config.rootPath = root.path
            config.indexSystemDirs = true
            let scanner = Scanner(config: config, threads: 1)
            var hookFired = false
            var hookError: Error?
            scanner.installDirectoryOpenHook { relativePath in
                guard relativePath == "replace/child" else { return }
                hookFired = true
                do {
                    try fm.moveItem(at: originalParent, to: movedParent)
                    try fm.createSymbolicLink(atPath: originalParent.path, withDestinationPath: external.path)
                } catch { hookError = error }
            }
            let output = try XCTUnwrap(scanner.run())
            XCTAssertTrue(hookFired, "scanner hook should run immediately before opening the queued descendant")
            XCTAssertNil(hookError)
            let store = IndexStore(scan: output, config: config)
            let paths = (0..<store.count).map { store.path(UInt32($0)) }
            XCTAssertFalse(paths.contains { $0.hasSuffix("external-only.txt") })
        }
    }

    func testT81UpdaterRejectsSymlinkedIntermediateAncestor() throws {
        try withTempDirectory { container in
            let root = container.appendingPathComponent("root")
            let originalParent = root.appendingPathComponent("replace")
            let target = container.appendingPathComponent("external")
            let eventRoot = originalParent.appendingPathComponent("newdir")
            let externalEventRoot = target.appendingPathComponent("newdir")
            let movedParent = container.appendingPathComponent("moved-replace")
            let fm = FileManager.default
            try fm.createDirectory(at: originalParent, withIntermediateDirectories: true)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            var config = IndexConfig.standard()
            config.rootPath = root.path
            config.indexSystemDirs = true
            let initialOutput = try XCTUnwrap(Scanner(config: config, threads: 1).run())
            let store = IndexStore(scan: initialOutput, config: config)
            store.write { store.buildHash() }

            try fm.createDirectory(at: eventRoot, withIntermediateDirectories: true)
            try fm.createDirectory(at: externalEventRoot, withIntermediateDirectories: true)
            try Data("external".utf8).write(to: externalEventRoot.appendingPathComponent("updater-target-only.txt"))
            let updater = IndexUpdater(config: config)
            var hookFired = false
            var hookError: Error?
            let eventPath = Array(eventRoot.path.utf8)
            updater.onSubtreeDirectoryOpen = { bytes in
                guard bytes.elementsEqual(eventPath) else { return }
                hookFired = true
                do {
                    try fm.moveItem(at: originalParent, to: movedParent)
                    try fm.createSymbolicLink(atPath: originalParent.path, withDestinationPath: target.path)
                } catch { hookError = error }
            }
            _ = updater.apply([FSChange(path: eventRoot.path, eventId: 1)], to: store)
            XCTAssertTrue(hookFired, "updater hook should run before resolving the subtree root")
            XCTAssertNil(hookError)
            XCTAssertFalse((0..<store.count).contains { store.name(UInt32($0)) == "updater-target-only.txt" })
        }
    }
}
