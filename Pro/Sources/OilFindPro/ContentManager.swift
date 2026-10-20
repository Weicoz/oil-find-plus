import Foundation
import SQLite3
import OilFindCore

public struct ContentSearchHit {
    public let path: String
    public let snippet: String
    public let highlightRanges: [NSRange]

    public init(path: String, snippet: String, highlightRanges: [NSRange]) {
        self.path = path
        self.snippet = snippet
        self.highlightRanges = highlightRanges
    }
}

public final class ContentManager {
    public static let shared = ContentManager()

    private var writeDb: OpaquePointer?
    private var readDb: OpaquePointer?
    private let queue = DispatchQueue(label: "org.oiloil.find.pro.content", qos: .background)
    private let documentExtractor = DocumentExtractor()
    private let imageRecognizer = ImageRecognizer()

    private let lock = NSRecursiveLock()
    private let searchLock = NSLock()
    private var isIndexing = false
    private var isBackgroundBusy = false
    private var isMemoryPressured = false
    private var typingUntil = Date.distantPast
    private var pendingSources: [SearchSource]?
    private var lastSources: [SearchSource]?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var isCachedStmt: OpaquePointer?
    private var saveDocStmt: OpaquePointer?
    private var saveFtsStmt: OpaquePointer?
    private var inTransaction = false
    private var uncommittedCount = 0

    private var isOcrEnabledUnsafe: Bool {
        if UserDefaults.standard.object(forKey: "proOcrEnabled") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "proOcrEnabled")
    }

    public var isOcrEnabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return isOcrEnabledUnsafe
        }
        set {
            setOcrEnabled(newValue)
        }
    }

    public func setOcrEnabled(_ enabled: Bool) {
        lock.lock()
        let old = UserDefaults.standard.object(forKey: "proOcrEnabled") as? Bool ?? true
        UserDefaults.standard.set(enabled, forKey: "proOcrEnabled")
        if !enabled {
            pendingSources = nil
        }
        let sources = lastSources
        lock.unlock()
        if enabled && !old, let sources = sources {
            startIndexing(sources: sources)
        }
    }

    private init() {
        openDatabase()
        setupMemoryPressureMonitoring()
    }

    deinit {
        memoryPressureSource?.cancel()
        commitTransactionIfNeeded()
        if let stmt = isCachedStmt { sqlite3_finalize(stmt) }
        if let stmt = saveDocStmt { sqlite3_finalize(stmt) }
        if let stmt = saveFtsStmt { sqlite3_finalize(stmt) }
        if let db = writeDb {
            sqlite3_close(db)
        }
        if let db = readDb {
            sqlite3_close(db)
        }
    }

    private func beginTransactionIfNeeded() {
        guard let db = writeDb, !inTransaction else { return }
        if sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil) == SQLITE_OK {
            inTransaction = true
            uncommittedCount = 0
        }
    }

    private func commitTransactionIfNeeded() {
        guard let db = writeDb, inTransaction else { return }
        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
        // 提交后把页缓存与 lookaside 还给系统，常驻堆内存不随索引规模增长。
        sqlite3_db_release_memory(db)
        inTransaction = false
        uncommittedCount = 0
    }

    private func setupMemoryPressureMonitoring() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical, .normal], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            let data = source.data
            self.lock.lock()
            if data.contains(.critical) || data.contains(.warning) {
                self.isMemoryPressured = true
            } else if data.contains(.normal) {
                self.isMemoryPressured = false
            }
            self.lock.unlock()
        }
        source.resume()
        self.memoryPressureSource = source
    }

    public func setBackgroundBusy(_ busy: Bool) {
        lock.lock()
        isBackgroundBusy = busy
        lock.unlock()
    }

    public func recordTyping() {
        lock.lock()
        typingUntil = Date().addingTimeInterval(1.5)
        lock.unlock()
    }

    private func shouldYield() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if !isOcrEnabledUnsafe {
            return true
        }
        if isBackgroundBusy || Date() < typingUntil {
            return true
        }
        if isMemoryPressured {
            return true
        }
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .serious || thermal == .critical {
            return true
        }
        return false
    }

    private func openDatabase() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Oil Find")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("oilfind_pro_fts.sqlite3")

        // 1. Writer connection (ReadWrite + Create + FullMutex)
        let writeFlags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(dbURL.path, &writeDb, writeFlags, nil) == SQLITE_OK {
            sqlite3_busy_timeout(writeDb, 5000)
            // mmap_size 让页缓存走只读文件映射：干净文件页不计入物理内存。
            sqlite3_exec(writeDb, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA cache_size = -1000; PRAGMA temp_store = MEMORY; PRAGMA mmap_size = 268435456;", nil, nil, nil)
            let schema = """
            CREATE TABLE IF NOT EXISTS docs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                path TEXT UNIQUE,
                size INTEGER,
                mtime INTEGER,
                kind INTEGER,
                content TEXT
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS docs_fts USING fts5(content, path UNINDEXED);
            """
            sqlite3_exec(writeDb, schema, nil, nil, nil)
        }

        // 2. Dedicated Reader connection (ReadOnly + FullMutex) for UI/search queue
        let readFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(dbURL.path, &readDb, readFlags, nil) != SQLITE_OK {
            _ = sqlite3_open_v2(dbURL.path, &readDb, writeFlags, nil)
        }
        if let rDb = readDb {
            sqlite3_busy_timeout(rDb, 5000)
            sqlite3_exec(rDb, "PRAGMA query_only = YES; PRAGMA cache_size = -1000; PRAGMA mmap_size = 268435456;", nil, nil, nil)
        }
    }

    public func startIndexing(sources: [SearchSource]) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self.lastSources = sources
            guard self.isOcrEnabledUnsafe else {
                self.lock.unlock()
                return
            }
            if self.isIndexing {
                self.pendingSources = sources
                self.lock.unlock()
                return
            }
            self.isIndexing = true
            self.lock.unlock()

            self.runIndexingLoop(sources: sources)
        }
    }

    private func runIndexingLoop(sources: [SearchSource]) {
        var currentSources = sources
        while true {
            guard isOcrEnabled else {
                lock.lock()
                isIndexing = false
                pendingSources = nil
                lock.unlock()
                break
            }

            scanAndIndex(sources: currentSources)

            lock.lock()
            if let next = pendingSources, isOcrEnabledUnsafe {
                pendingSources = nil
                currentSources = next
                lock.unlock()
            } else {
                isIndexing = false
                lock.unlock()
                break
            }
        }
    }

    private func isEligibleForContentIndex(path: String) -> Bool {
        // 1. Exclude macOS system directories
        if path.hasPrefix("/System/") || path.hasPrefix("/Library/") ||
           path.hasPrefix("/private/") || path.hasPrefix("/usr/") ||
           path.hasPrefix("/bin/") || path.hasPrefix("/sbin/") ||
           path.hasPrefix("/opt/") || path.hasPrefix("/dev/") ||
           path.hasPrefix("/cores/") {
            return false
        }

        // 2. Exclude user's ~/Library/ (caches, app containers, preferences)
        let home = NSHomeDirectory()
        if path.hasPrefix(home + "/Library/") {
            return false
        }

        // 3. Exclude app bundles & framework internal assets
        if path.contains(".app/") || path.contains(".framework/") ||
           path.contains(".plugin/") || path.contains(".bundle/") {
            return false
        }

        // 4. Exclude hidden dirs, dependencies, build artifacts in path components
        let components = path.split(separator: "/")
        for comp in components {
            if comp.hasPrefix(".") {
                return false
            }
            if comp == "node_modules" || comp == "Pods" || comp == "Carthage" ||
               comp == "DerivedData" || comp == "build" || comp == ".build" ||
               comp == "dist" || comp == "target" || comp == "vendor" ||
               comp == "site-packages" || comp == "__pycache__" || comp == ".Trash" {
                return false
            }
        }

        return true
    }

    private func scanAndIndex(sources: [SearchSource]) {
        var processedCount = 0
        let recentCutoff = UInt32(max(0, Int64(Date().timeIntervalSince1970) - 30 * 86400))

        // Two-phase scan: Pass 1 for files modified in the last 30 days (high priority);
        // Pass 2 for older/archived files (background backlog).
        for pass in 1...2 {
            for source in sources where source.isOnline {
                let store = source.store
                let count = store.read { store.count }
                for i in 1..<count {
                    guard isOcrEnabled else {
                        commitTransactionIfNeeded()
                        return
                    }

                    // Yield while user is typing, system is under thermal/memory pressure, or primary index is rebuilding
                    while shouldYield() {
                        commitTransactionIfNeeded()
                        guard isOcrEnabled else { return }
                        Thread.sleep(forTimeInterval: 0.5)
                    }

                    let (path, isDir, deleted, mtime, size) = store.read { () -> (String, Bool, Bool, UInt32, UInt64) in
                        let isDir = (store.flags[i] & SiftFlag.dir) != 0
                        let deleted = (store.flags[i] & SiftFlag.deleted) != 0
                        return (store.path(UInt32(i)), isDir, deleted, store.mtime[i], store.size(UInt32(i)))
                    }
                    if isDir || deleted { continue }

                    // Pass 1: only recent files (mtime >= recentCutoff); Pass 2: only older files
                    if pass == 1 && mtime < recentCutoff { continue }
                    if pass == 2 && mtime >= recentCutoff { continue }

                    // Only index human-accessible documents/images, skipping machine assets and packages
                    guard isEligibleForContentIndex(path: path) else { continue }

                    let ext = (path as NSString).pathExtension.lowercased()
                    let isDoc = DocumentExtractor.supportedExtensions.contains(ext)
                    let isImg = ["png", "jpg", "jpeg", "heic", "webp"].contains(ext)
                    if !isDoc && !isImg { continue }

                    // Skip oversized documents (> 25MB) or tiny/oversized images
                    if isDoc && size > 25_000_000 { continue }
                    if isImg && (size < 10_000 || size > 30_000_000) { continue }

                    // Check cache
                    if isCached(path: path, size: Int64(size), mtime: Int64(mtime)) {
                        continue
                    }

                    // Extract content within autoreleasepool so bitmaps, memory buffers, and temporary objects are immediately freed
                    autoreleasepool {
                        var text: String?
                        if isDoc {
                            text = documentExtractor.extract(path: path)?.text
                        } else if isImg {
                            text = imageRecognizer.recognize(path: path, cancelled: { [weak self] in self?.shouldYield() == true })?.text
                        }

                        if let text = text, !text.isEmpty {
                            saveDocument(path: path, size: Int64(size), mtime: Int64(mtime), kind: isDoc ? 3 : 4, content: text)
                        }
                    }

                    processedCount += 1
                    if isImg {
                        usleep(80_000) // 80ms yield after each image OCR to keep CPU cold
                    } else if processedCount % 5 == 0 {
                        usleep(30_000) // 30ms yield to prevent CPU/thermal spikes
                    }
                }
            }
        }
        commitTransactionIfNeeded()
    }

    public func clearDatabase(completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            if let stmt = self.isCachedStmt { sqlite3_finalize(stmt); self.isCachedStmt = nil }
            if let stmt = self.saveDocStmt { sqlite3_finalize(stmt); self.saveDocStmt = nil }
            if let stmt = self.saveFtsStmt { sqlite3_finalize(stmt); self.saveFtsStmt = nil }
            if self.inTransaction, let db = self.writeDb {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                self.inTransaction = false
                self.uncommittedCount = 0
            }
            if let db = self.writeDb { sqlite3_close(db); self.writeDb = nil }
            if let db = self.readDb { sqlite3_close(db); self.readDb = nil }

            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = appSupport.appendingPathComponent("Oil Find")
            let dbURL = dir.appendingPathComponent("oilfind_pro_fts.sqlite3")
            let walURL = dir.appendingPathComponent("oilfind_pro_fts.sqlite3-wal")
            let shmURL = dir.appendingPathComponent("oilfind_pro_fts.sqlite3-shm")

            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(at: walURL)
            try? FileManager.default.removeItem(at: shmURL)

            self.openDatabase()
            let sources = self.lastSources
            self.lock.unlock()

            if self.isOcrEnabled, let sources = sources {
                self.startIndexing(sources: sources)
            }
            DispatchQueue.main.async { completion?() }
        }
    }

    public func databaseSizeString() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Oil Find")
        let dbURL = dir.appendingPathComponent("oilfind_pro_fts.sqlite3")
        let walURL = dir.appendingPathComponent("oilfind_pro_fts.sqlite3-wal")
        var total: UInt64 = 0
        if let attr = try? FileManager.default.attributesOfItem(atPath: dbURL.path), let size = attr[.size] as? UInt64 {
            total += size
        }
        if let attr = try? FileManager.default.attributesOfItem(atPath: walURL.path), let size = attr[.size] as? UInt64 {
            total += size
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(total))
    }

    private func isCached(path: String, size: Int64, mtime: Int64) -> Bool {
        guard let db = writeDb else { return false }
        if isCachedStmt == nil {
            let sql = "SELECT id FROM docs WHERE path = ? AND size = ? AND mtime = ? LIMIT 1;"
            sqlite3_prepare_v2(db, sql, -1, &isCachedStmt, nil)
        }
        guard let stmt = isCachedStmt else { return false }
        defer {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }
        sqlite3_bind_text(stmt, 1, (path as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(stmt, 2, size)
        sqlite3_bind_int64(stmt, 3, mtime)

        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func saveDocument(path: String, size: Int64, mtime: Int64, kind: Int, content: String) {
        guard let db = writeDb else { return }
        beginTransactionIfNeeded()

        if saveDocStmt == nil {
            let sql = """
            INSERT INTO docs (path, size, mtime, kind) VALUES (?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET size=excluded.size, mtime=excluded.mtime;
            """
            sqlite3_prepare_v2(db, sql, -1, &saveDocStmt, nil)
        }
        if let stmt = saveDocStmt {
            sqlite3_bind_text(stmt, 1, (path as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 2, size)
            sqlite3_bind_int64(stmt, 3, mtime)
            sqlite3_bind_int(stmt, 4, Int32(kind))
            sqlite3_step(stmt)
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }

        if saveFtsStmt == nil {
            let ftsSql = "INSERT INTO docs_fts (content, path) VALUES (?, ?);"
            sqlite3_prepare_v2(db, ftsSql, -1, &saveFtsStmt, nil)
        }
        if let ftsStmt = saveFtsStmt {
            sqlite3_bind_text(ftsStmt, 1, (content as NSString).utf8String, -1, nil)
            sqlite3_bind_text(ftsStmt, 2, (path as NSString).utf8String, -1, nil)
            sqlite3_step(ftsStmt)
            sqlite3_reset(ftsStmt)
            sqlite3_clear_bindings(ftsStmt)
        }

        uncommittedCount += 1
        if uncommittedCount >= 50 {
            commitTransactionIfNeeded()
        }
    }

    public func search(query: String, limit: Int = 100, isCancelled: @escaping () -> Bool) -> [ContentSearchHit] {
        guard !query.isEmpty, isOcrEnabled else { return [] }
        searchLock.lock()
        defer { searchLock.unlock() }
        guard let db = readDb else { return [] }
        var results: [ContentSearchHit] = []

        let cleanQuery = query.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }
            .joined(separator: " ")
        guard !cleanQuery.isEmpty else { return [] }

        var stmt: OpaquePointer?
        let sql = """
        SELECT path, snippet(docs_fts, 0, '[[', ']]', '...', 15)
        FROM docs_fts
        WHERE docs_fts MATCH ?
        LIMIT ?;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, (cleanQuery as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        while sqlite3_step(stmt) == SQLITE_ROW {
            if isCancelled() { break }
            guard let pathCStr = sqlite3_column_text(stmt, 0),
                  let snippetCStr = sqlite3_column_text(stmt, 1) else {
                continue
            }
            let path = String(cString: pathCStr)
            let snippet = String(cString: snippetCStr)

            let (cleanedSnippet, ranges) = parseHighlights(from: snippet)
            results.append(ContentSearchHit(path: path, snippet: cleanedSnippet, highlightRanges: ranges))
        }
        sqlite3_finalize(stmt)
        return results
    }

    private func parseHighlights(from text: String) -> (String, [NSRange]) {
        var clean = ""
        var ranges: [NSRange] = []
        var cursor = text.startIndex

        while cursor < text.endIndex {
            if text[cursor...].hasPrefix("[[") {
                let start = text.index(cursor, offsetBy: 2)
                if let end = text[start...].range(of: "]]") {
                    let matchText = String(text[start..<end.lowerBound])
                    let location = clean.utf16.count
                    clean.append(matchText)
                    let length = matchText.utf16.count
                    ranges.append(NSRange(location: location, length: length))
                    cursor = end.upperBound
                    continue
                }
            }
            clean.append(text[cursor])
            cursor = text.index(after: cursor)
        }
        return (clean, ranges)
    }
}
