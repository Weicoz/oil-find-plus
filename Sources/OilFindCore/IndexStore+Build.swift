import Foundation
import Darwin

private struct AltBuildBuffer {
    var owners: [UInt32] = []
    var lengths: [UInt32] = []
    var bytes: [UInt8] = []
    mutating func append(owner: UInt32, key: [UInt8]) {
        owners.append(owner)
        lengths.append(UInt32(key.count))
        bytes.append(contentsOf: key)
    }
}

private struct AltReference {
    var owner: UInt32
    var worker: Int
    var ordinal: Int
    var offset: Int
    var length: Int
}

extension IndexStore {
    /// 建库，但不消费调用方的扫描缓冲：调用方仍持有 buffers，建库期间「扫描缓冲 + 索引数组」同时驻留。
    /// 重建索引的热路径请用 init(consuming:config:)，内存峰值低得多。
    public convenience init(scan: ScanOutput, config: IndexConfig) {
        var copy = scan
        self.init(consuming: &copy, config: config, releaseScanPages: false)
    }

    /// 建库并消费扫描缓冲：每拷完一个 worker 就把它那几段数组还给系统。
    /// 扫描缓冲与索引数组此消彼长，峰值从「两份之和」降到「较大者」——
    /// 全盘重建时这一项就是几百 MB（names 段往往比整个索引的一半还大）。
    ///
    /// 契约：调用后 `scan.buffers` 会被清空，且底层页会被标记为可回收（见 MemoryReclaim.swift），
    /// 因此调用方不得再保留 ScanOutput 的副本、也不得再读其中的数组。
    public convenience init(consuming scan: inout ScanOutput, config: IndexConfig) {
        self.init(consuming: &scan, config: config, releaseScanPages: true)
    }

    private convenience init(consuming scan: inout ScanOutput, config: IndexConfig, releaseScanPages: Bool) {
        let workerCount = scan.buffers.count
        // 名字长度只用来算前缀和，算完立刻归还：省下一份 4 字节/条目的数组。
        let rawLen: Int
        let off: [UInt32]
        do {
            var lengths = [UInt32](repeating: 0, count: scan.count)
            lengths.withUnsafeMutableBufferPointer { lengthPointer in
                DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
                    let buffer = scan.buffers[worker]
                    for j in buffer.ids.indices { lengthPointer[Int(buffer.ids[j])] = buffer.nameLens[j] }
                }
            }
            var offsets = [UInt32](repeating: 0, count: scan.count + 1)
            for i in 0..<scan.count { offsets[i+1] = offsets[i] + lengths[i] }
            rawLen = Int(offsets[scan.count])
            off = offsets
            lengths.releasePagesForReuse()
        }

        _ = Pinyin.shared
        var altBuffers = Array(repeating: AltBuildBuffer(), count: workerCount)
        altBuffers.withUnsafeMutableBufferPointer { outputs in
            DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
                let buffer = scan.buffers[worker]
                var output = AltBuildBuffer()
                var full: [UInt8] = [], initials: [UInt8] = []
                full.reserveCapacity(2048); initials.reserveCapacity(2048)
                buffer.nameBytes.withUnsafeBufferPointer { allNames in
                    var offset = 0
                    for j in buffer.ids.indices {
                        let len = Int(buffer.nameLens[j])
                        let name = UnsafeBufferPointer(start: allNames.baseAddress!.advanced(by: offset), count: len)
                        offset += len
                        if !name.contains(where: { $0 >= 128 }) { continue }
                        if Pinyin.shared.keys(for: name, full: &full, initials: &initials) {
                            output.append(owner: buffer.ids[j], key: full)
                            output.append(owner: buffer.ids[j], key: initials)
                        } else {
                            full.removeAll(keepingCapacity: true)
                            full.append(contentsOf: String(decoding: name, as: UTF8.self).lowercased().utf8)
                            var differs = full.count != name.count
                            if !differs {
                                for k in name.indices {
                                    let byte = name[k]
                                    if full[k] != (byte >= 65 && byte <= 90 ? byte | 32 : byte) { differs = true; break }
                                }
                            }
                            if differs { output.append(owner: buffer.ids[j], key: full) }
                        }
                    }
                }
                outputs[worker] = output
            }
        }
        var refs: [AltReference] = []
        for worker in altBuffers.indices {
            let buffer = altBuffers[worker]
            var offset = 0
            for ordinal in buffer.owners.indices {
                let len = Int(buffer.lengths[ordinal])
                refs.append(AltReference(owner: buffer.owners[ordinal], worker: worker, ordinal: ordinal, offset: offset, length: len))
                offset += len
            }
        }
        // 必须按 owner 排序：Searcher 用 lowerBound(altOwner) 二分找某个条目的备用名。
        refs.sort { $0.owner == $1.owner ? ($0.worker == $1.worker ? $0.ordinal < $1.ordinal : $0.worker < $1.worker) : $0.owner < $1.owner }
        let altLen = refs.reduce(0) { $0 + $1.length }
        let caseSensitiveNames = config.rootPath.withCString { pathconf($0, _PC_CASE_SENSITIVE) == 1 }
        self.init(rootPath: config.rootPath, count: scan.count, namesLen: rawLen, altCount: refs.count, altLen: altLen, fingerprint: config.fingerprint, homeIndex: scan.homeIndex, finishedAt: scan.finishedAt, caseSensitiveNames: caseSensitiveNames)
        scopeFingerprint = config.scopeFingerprint
        coverage = scan.coverage
        nameOff.update(from: off, count: off.count)
        parent[0] = 0; sizeC[0] = 0; mtime[0] = 0; flags[0] = SiftFlag.dir
        depth[0] = UInt8(min(config.rootPath.split(separator: "/").count, 255)); kind[0] = 1
        // 逐 worker 拷贝：拷完一个就把它那 9 段数组标成可回收再清掉，索引数组涨多少、扫描缓冲就退多少。
        // 这里不用 concurrentPerform 换并行——并行时所有 worker 的缓冲必须同时存活，峰值回到「两份之和」。
        scan.buffers.withUnsafeMutableBufferPointer { buffers in
            for worker in 0..<buffers.count {
                let buffer = buffers[worker]
                buffer.nameBytes.withUnsafeBufferPointer { raw in
                    var position = 0
                    for j in buffer.ids.indices {
                        let i = Int(buffer.ids[j]), len = Int(buffer.nameLens[j])
                        parent[i] = buffer.parents[j]; sizeC[i] = buffer.sizes[j]; mtime[i] = buffer.mtimes[j]
                        flags[i] = buffer.flags[j]; depth[i] = buffer.depths[j]; kind[i] = buffer.kinds[j]
                        if len > 0 { names.advanced(by: Int(off[i])).update(from: raw.baseAddress!.advanced(by: position), count: len) }
                        position += len
                    }
                }
                if releaseScanPages {
                    buffer.ids.releasePagesForReuse(); buffer.parents.releasePagesForReuse(); buffer.sizes.releasePagesForReuse()
                    buffer.mtimes.releasePagesForReuse(); buffer.flags.releasePagesForReuse(); buffer.depths.releasePagesForReuse()
                    buffer.kinds.releasePagesForReuse(); buffer.nameLens.releasePagesForReuse(); buffer.nameBytes.releasePagesForReuse()
                }
                buffers[worker] = ScanBuffer()
            }
        }
        var altPosition = 0
        for (j, ref) in refs.enumerated() {
            altOff[j] = UInt32(altPosition)
            altOwner[j] = ref.owner
            altBuffers[ref.worker].bytes.withUnsafeBufferPointer { bytes in
                if ref.length > 0 { altNames.advanced(by: altPosition).update(from: bytes.baseAddress!.advanced(by: ref.offset), count: ref.length) }
            }
            altPosition += ref.length
        }
        altOff[refs.count] = UInt32(altPosition)
        off.releasePagesForReuse()
    }
}
