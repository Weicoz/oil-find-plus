import Foundation
import XCTest
@testable import OilFindCore

extension XCTestCase {
    func skipIfCI(_ reason: String) throws {
        if ProcessInfo.processInfo.environment["CI"] == "true" {
            throw XCTSkip(reason)
        }
    }
    /// 手写 v3 布局：段紧凑排列、载入即 memcpy，用于验证旧文件仍可读并升级为 v4。
    /// writeCoverage=false 时不写统计段（旧文件可以没有它，载入后统计为空）。
    func writeLegacyV3File(_ store: IndexStore, to url: URL, writeCoverage: Bool = true) throws {
        let coverage = writeCoverage ? try JSONEncoder().encode(store.coverage) : Data()
        var header = [UInt8](repeating: 0, count: 256)
        header.replaceSubrange(0..<8, with: Array("SIFTIDX\0".utf8))
        func set32(_ value: UInt32, _ at: Int) { for i in 0..<4 { header[at+i] = UInt8(truncatingIfNeeded: value >> (i*8)) } }
        func set64(_ value: UInt64, _ at: Int) { for i in 0..<8 { header[at+i] = UInt8(truncatingIfNeeded: value >> (i*8)) } }
        set32(3, 8); set32(UInt32(coverage.count), 116); set32(0, 124); set32(0, 140); set32(UInt32(store.count), 12); set64(UInt64(store.namesLen), 16)
        set32(UInt32(store.altCount), 24); set32(UInt32(store.rootPath.utf8.count), 28); set64(UInt64(store.altLen), 32)
        set64(store.lastEventId, 40); set64(store.configFingerprint, 48); set64(store.scanFinishedAt, 56)
        for (i, byte) in store.fsEventsUUID.utf8.prefix(40).enumerated() { header[64+i] = byte }
        set32(store.homeIndex, 104); set32(store.deletedCount, 108); header[112] = store.caseSensitiveNames ? 1 : 0
        set64(store.scopeFingerprint, 120)
        var bytes = header
        bytes += Array(store.rootPath.utf8)
        func append<T>(_ pointer: UnsafeMutablePointer<T>, _ count: Int) {
            bytes += UnsafeRawBufferPointer(start: UnsafeRawPointer(pointer), count: count * MemoryLayout<T>.stride)
        }
        append(store.nameOff, store.count + 1); append(store.parent, store.count)
        append(store.sizeC, store.count); append(store.mtime, store.count)
        append(store.flags, store.count); append(store.depth, store.count); append(store.kind, store.count)
        append(store.names, store.namesLen)
        append(store.altOff, store.altCount + 1); append(store.altOwner, store.altCount); append(store.altNames, store.altLen)
        bytes += coverage
        try Data(bytes).write(to: url)
    }
}
