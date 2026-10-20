import Darwin

/// 把「即将归还、且不再访问」的匿名内存标记成可回收页。
///
/// macOS 的 malloc 在 free 之后仍把这些页留在 zone 的空闲链表里，并且照样算进 phys_footprint：
/// 实测 200 MB 的 Swift 数组释放后 phys_footprint 仍是 192 MB，`malloc_zone_pressure_relief` 也回收不掉
/// （relief 返回 0）。显式 `madvise(MADV_FREE_REUSABLE)` 才会立刻从常驻内存里消失（实测 192 MB → 2 MB）。
///
/// 调用约束：只在确定自己是唯一持有者、且之后再也不会读这段内存时调用——
/// 标记之后内核随时可以丢弃页内容（malloc 复用这些页时按「未初始化」对待，正好符合 malloc 的契约）。
/// `madvise` 只接受页对齐地址，而 malloc 返回的块首地址通常不是页边界（前面还有块头），
/// 所以这里只标记「完全落在块内」的整页：首尾两个不满一页的片段留在原处（malloc 的元数据就在那里）。
func releasePagesToSystem(_ base: UnsafeMutableRawPointer?, bytes: Int) {
    guard let base, bytes > 0 else { return }
    let page = Int(getpagesize())
    let address = Int(bitPattern: base)
    let start = (address + page - 1) & ~(page - 1)
    let length = address + bytes - start
    guard length >= page else { return }
    _ = madvise(UnsafeMutableRawPointer(bitPattern: start), length, MADV_FREE_REUSABLE)
}

extension Array {
    /// 丢弃这个数组前，先把底层页交还给系统（否则它会在 phys_footprint 里一直挂着）。
    func releasePagesForReuse() {
        guard !isEmpty else { return }
        let bytes = capacity * MemoryLayout<Element>.stride
        withUnsafeBufferPointer { buffer in
            releasePagesToSystem(UnsafeMutableRawPointer(mutating: buffer.baseAddress), bytes: bytes)
        }
    }
}
