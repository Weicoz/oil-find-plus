import Foundation
import Darwin
import CoreServices
import os

public final class IndexManager {
    public enum State { case idle, loading, scanning, ready }
    // The requested config belongs to eventQueue; each scan captures its own value.
    private var config: IndexConfig
    private var settingsObserver: NSObjectProtocol?
    private let settingsDefaults: UserDefaults?
    private var offline = false
    private let dbURL: URL
    private let volumeUUID: String?
    private let lock = NSLock()
    private let eventQueue = DispatchQueue(label: "com.oiloil.find.events", qos: .utility)
    private let scanQueue = DispatchQueue(label: "com.oiloil.find.scan", qos: .utility)
    private let saveQueue = DispatchQueue(label: "com.oiloil.find.save", qos: .background)
    private let eventKey = DispatchSpecificKey<Bool>(), saveKey = DispatchSpecificKey<Bool>()
    private var currentState: State = .idle, currentStore: IndexStore?, currentScanner: Scanner?
    private var rescanning = false, active = false, generation = 0, summary: ApplySummary?
    private var scanWatcher: FSWatcher?, bufferedEvents: [String: FSChange] = [:], bufferingToken: Int?, bufferedRescan = false
    private var bufferedEventBytes = 0
    // 后台重建被限速到每秒 4000 项，200 万条目的重建要跑几分钟，这段时间事件只进缓冲。
    // 上限压得太低会溢出并置 bufferedRescan，重建完成又立刻排队下一轮，形成自我喂养的重扫循环。
    internal var bufferedEventByteLimit = 32 * 1024 * 1024
    /// 缓冲前的预过滤配置（取本轮扫描所用配置）。排除目录（~/Library、/private、.git、.build…）
    /// 占全盘事件的大半，它们在 apply 时必然被拒收，提前丢掉才不会把缓冲挤到溢出。
    private var bufferFilterConfig: IndexConfig?
    /// 连续以「丢事件」收尾的重建次数。第二次起恢复重建按指数退避（5 分钟起，封顶 1 小时），
    /// 机器持续高负载时不再让「重建→丢失→重建」首尾相接地整盘遍历并整份写盘。
    private var lossStreak = 0, recoveryNotBefore: CFAbsoluteTime = 0, recoveryDeferred = false
    /// 扫描期间丢失信号的旗标并集与缓冲是否溢出，用来判断这次损失能否靠回放历史补齐。
    private var bufferedLossFlags: UInt32 = 0, bufferedOverflow = false
    /// 「回放补齐」的预算：滚动 10 分钟内最多 8 次。每次都从已应用的游标重放，突发的成串 UserDropped
    /// 不会漏件；超出预算说明回放补不住，改走整盘重建（受上面的退避约束）。
    private var recentReplays: [CFAbsoluteTime] = []
    internal static let replayBudget = 8, replayWindow: CFAbsoluteTime = 600
    /// 实时丢件后延迟重开流再回放：系统级事件风暴期间立即重开会在 0.1 秒内再次被丢，
    /// 一秒内就烧光预算（实测 5 次回放 0.6 秒耗尽后退回整盘重建）。延迟按窗口内已回放次数翻倍，
    /// 0.5 秒起、封顶 30 秒，8 次预算约覆盖 75 秒的风暴。停流期间 fseventsd 照常记账，回放不漏件。
    internal static var replayDelayBase: CFAbsoluteTime = 0.5
    internal static let replayDelayCap: CFAbsoluteTime = 30
    private var replayPending = false
    /// UserDropped 只表示本进程这一路客户端被丢件，fseventsd 历史日志仍完整，可回放补齐；
    /// 内核丢失、事件 ID 回绕、根变化意味着历史本身不可信，必须整盘重建。
    internal static func replayableLoss(_ flags: UInt32) -> Bool {
        flags & UInt32(kFSEventStreamEventFlagUserDropped) != 0
            && flags & UInt32(kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged) == 0
    }
    private func takeReplayBudget() -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        recentReplays.removeAll { now - $0 >= Self.replayWindow }
        guard recentReplays.count < Self.replayBudget else { return false }
        recentReplays.append(now); return true
    }
    private var nextReplayDelay: CFAbsoluteTime {
        min(Self.replayDelayBase * pow(2, Double(max(0, recentReplays.count - 1))), Self.replayDelayCap)
    }
    /// 定时保存的节流依据：上次落盘时的写入计数与时刻。映射态下改动只产生少量写时复制页，
    /// 不必每 30 分钟整份重写 70MB+；FSEvents 回放会补齐两次保存之间的改动。
    private var savedMutations: UInt64 = 0, savedAt = CFAbsoluteTimeGetCurrent()
    internal static let periodicSaveMutations: UInt64 = 50_000
    internal static let periodicSaveMaxAge: CFAbsoluteTime = 4 * 3600
    /// 发布版也记录整盘重建的起因与收尾：重建一次就整份写盘，只靠 DEBUG 日志无法在用户机器上定位。
    /// 只在重建、丢事件、缓冲溢出这类低频节点写一行，不记具体路径。
    private static let log = Logger(subsystem: "com.oiloil.find", category: "index")
    private var watcher: FSWatcher?, timer: DispatchSourceTimer?
    internal var onBeforeLoadedHashBuild: (() -> Void)?
    internal var onRescanStart: (() -> Void)?
    internal var onScannerCreated: ((Scanner) -> Void)?
    internal var onBufferedEvents: (([FSChange]) -> Void)?
    internal var onUpdaterCreated: ((IndexUpdater) -> Void)?
    private var recoveryRescanPending = false
    // Scheduling a scan does not repair the published catalog's replay interval.
    private var unresolvedLossCursor: UInt64?
    private var watcherEpoch: UInt64 = 0, scanStartEventId: UInt64 = 0
    internal var watcherEpochForTesting: UInt64 {
        DispatchQueue.getSpecific(key: eventKey) == true ? watcherEpoch : eventQueue.sync { watcherEpoch }
    }
    private var updater: IndexUpdater?
    private weak var savedStore: IndexStore?
    private var savedVersion: UInt64 = 0
    private var pendingNotification: DispatchWorkItem?, lastNotification = -Double.infinity
    private var stateCallback: ((State) -> Void)?, indexCallback: (() -> Void)?, batchCallback: ((ApplySummary) -> Void)?
    private var replayCount = 0, dataPrefix = false, hashMs = 0.0
    /// 进程内首次创建管理器的时刻，用于判定同目录下哪些临时文件是上次崩溃的残留。
    private let startedAt = Date()
    /// 后台重建索引的吞吐上限（entries/s）。0 关闭；可用 OILFIND_SCAN_EPS 覆盖。
    /// 后台重建本来就不阻塞搜索（旧索引仍在服务），慢一点换取 CPU 常驻个位数。
    public static let backgroundScanEntriesPerSecond: Double = {
        if let raw = ProcessInfo.processInfo.environment["OILFIND_SCAN_EPS"], let value = Double(raw), value >= 0 {
            return value
        }
        return 4000
    }()
    public init(config: IndexConfig, dbURL: URL, volumeUUID: String? = nil, settingsDefaults: UserDefaults? = .standard) {
        self.config = config; self.dbURL = dbURL; self.volumeUUID = volumeUUID
        self.settingsDefaults = settingsDefaults
        if let values = settingsDefaults?.stringArray(forKey: "excludedExtensions") { self.config.excludedExtensions = Set(values) }
        eventQueue.setSpecific(key: eventKey, value: true); saveQueue.setSpecific(key: saveKey, value: true)
        if let settingsDefaults {
            settingsObserver = NotificationCenter.default.addObserver(forName: SettingsPreferences.excludedExtensionsChanged, object: settingsDefaults, queue: nil) { [weak self] notification in
                guard let extensions = notification.userInfo?["extensions"] as? Set<String> else { return }
                self?.eventQueue.async { [weak self] in
                    guard let self, self.config.excludedExtensions != extensions else { return }
                    self.config.excludedExtensions = extensions
                    if self.locked({ self.offline }) { self.reloadOffline() }
                    else { self.beginRescan() }
                }
            }
        }
    }
    deinit { if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }; timer?.cancel(); pendingNotification?.cancel(); currentScanner?.cancel() }
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    public var state: State { locked { currentState } }
    public var store: IndexStore? { locked { currentStore } }
    public var scannedCount: Int { let scanner = locked { currentScanner }; return scanner?.scannedCount ?? 0 }
    public var isRescanning: Bool { locked { rescanning } }
    public var lastSummary: ApplySummary? { locked { summary } }
    public var replayedEventCount: Int { locked { replayCount } }
    public var reportedDataPrefix: Bool { locked { dataPrefix } }
    public var buildHashMs: Double { locked { hashMs } }
    public var onStateChange: ((State) -> Void)? { get { locked { stateCallback } } set { locked { stateCallback = newValue } } }
    public var onIndexChange: (() -> Void)? { get { locked { indexCallback } } set { locked { indexCallback = newValue } } }
    // Each batch is observable independently of the UI notification throttle.
    public var onApply: ((ApplySummary) -> Void)? { get { locked { batchCallback } } set { locked { batchCallback = newValue } } }
    private func setState(_ state: State) {
        let callback = locked { () -> ((State) -> Void)? in
            if currentState == state { return nil }; currentState = state; return stateCallback
        }
        DispatchQueue.main.async { callback?(state) }
    }
    private func valid(_ token: Int) -> Bool { locked { active && generation == token } }
    private func device(config: IndexConfig) -> dev_t? {
        var s = stat(); guard stat(config.rootPath == "/" ? "/System/Volumes/Data" : config.rootPath, &s) == 0 else { return nil }
        return s.st_dev
    }
    private func mountedVolumeMatches(_ config: IndexConfig) -> Bool {
        guard let volumeUUID else { return true }
        guard let actual = try? URL(fileURLWithPath: config.rootPath).resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString else { return false }
        return actual.caseInsensitiveCompare(volumeUUID) == .orderedSame
    }
    private func deviceUUID(config: IndexConfig) -> String? { device(config: config).flatMap(FSWatcher.uuid) }
    private func fingerprint(_ config: IndexConfig) -> UInt64 { volumeUUID.map { config.fingerprint(volumeUUID: $0) } ?? config.fingerprint }
    private func cursorIsValid(_ store: IndexStore, config: IndexConfig, uuid: String?) -> Bool {
        guard let uuid, store.fsEventsUUID == uuid else { return false }
        guard volumeUUID != nil else { return true }
        guard let device = device(config: config) else { return false }
        let latest = FSWatcher.currentEventId(forDevice: device)
        // The per-device value can lag delivered events until the journal flushes.
        return store.lastEventId <= max(latest, FSWatcher.currentEventId())
    }
    public func startOffline() {
        eventQueue.async { [weak self] in
            guard let self, !self.locked({ self.active }) else { return }
            self.locked { self.active = true; self.offline = true }
            self.reloadOffline()
        }
    }
    private func scopeFingerprint(_ config: IndexConfig) -> UInt64 {
        var scope = config; scope.excludedExtensions = []
        return fingerprint(scope)
    }
    private func reloadOffline() {
        guard locked({ active && offline }) else { return }
        let token = locked { generation += 1; return generation }
        setState(.loading)
        let config = self.config
        scanQueue.async { [weak self] in
            guard let self, self.valid(token) else { return }
            let loaded = IndexStore.load(from: self.dbURL.path)
            self.eventQueue.async {
                guard self.valid(token) else { return }
                guard let loaded, loaded.configFingerprint == self.fingerprint(config)
                    || loaded.scopeFingerprint == self.scopeFingerprint(config)
                    || loaded.configFingerprint == self.scopeFingerprint(config) else {
                    self.locked { self.active = false; self.currentStore = nil }
                    self.setState(.idle); self.notifyIndex(replaced: true); return
                }
                if self.volumeUUID != nil { loaded.rebase(to: config.rootPath) }
                // Filter a fresh catalog in memory; retain the on-disk snapshot for undo and reconnect.
                if config.hasExcludedExtensions {
                    loaded.write {
                        var bucket = loaded.coverage[.fileType], changed = false
                        for i in 1..<loaded.count where loaded.isLive(UInt32(i)) && loaded.flags[i] & SiftFlag.dir == 0 {
                            guard config.excludesFile(name: loaded.nameBytes(UInt32(i))) else { continue }
                            bucket.count &+= 1
                            if bucket.examples.count < 5 {
                                let path = loaded.path(UInt32(i))
                                if !bucket.examples.contains(path) { bucket.examples.append(path) }
                            }
                            changed = loaded.remove(UInt32(i)) || changed
                        }
                        loaded.coverage.buckets[.fileType] = bucket
                        if changed { loaded.version &+= 1 }
                    }
                }
                self.locked { self.currentStore = loaded }
                self.saveQueue.sync { self.savedStore = loaded; self.savedVersion = loaded.version }
                self.setState(.ready); self.notifyIndex(replaced: true)
            }
        }
    }
    public func start() {
        eventQueue.async { [weak self] in
            guard let self, !self.locked({ self.active }) else { return }
            let token = self.locked { self.active = true; self.offline = false; self.replayCount = 0; self.dataPrefix = false; self.generation += 1; return self.generation }
            self.setState(.loading)
            // 上次崩溃可能留下整份索引临时文件（保存走 .tmp.<pid> + rename），启动时清掉。
            IndexStore.removeStaleTemporaryFiles(nextTo: self.dbURL.path, olderThan: self.startedAt)
            let config = self.config
            self.scanQueue.async { [weak self] in
                guard let self, self.valid(token) else { return }
                guard self.mountedVolumeMatches(config) else {
                    self.eventQueue.async { if self.valid(token) { self.locked { self.active = false }; self.setState(.idle) } }
                    return
                }
                let uuid = self.deviceUUID(config: config)
                let loaded = IndexStore.load(from: self.dbURL.path)
                if let s = loaded, s.configFingerprint == self.fingerprint(config),
                   (self.volumeUUID != nil || s.rootPath == config.rootPath), self.cursorIsValid(s, config: config, uuid: uuid) {
                    let rootChanged = s.rootPath != config.rootPath
                    if self.volumeUUID != nil { s.rebase(to: config.rootPath) }
                    self.eventQueue.async {
                        guard self.valid(token) else { return }
                        self.locked { self.currentStore = s; self.hashMs = 0 }
                        self.saveQueue.sync { self.savedStore = s; self.savedVersion = rootChanged ? UInt64.max : s.version }
                        self.setState(.ready); self.notifyIndex(replaced: true)
                        DispatchQueue.global(qos: .utility).async { _ = Pinyin.shared }
                        // 文件自带可用哈希表时才算「载入即完整」；表缺失或校验不过就要重建并补写回文件。
                        let carriedTable = s.read({ s.hashReady })
                        if carriedTable {
                            // v4 文件自带哈希表：省掉 13MB 临时表与一次全量构建。
                            self.locked { self.hashMs = 0 }
                        } else {
                            self.onBeforeLoadedHashBuild?()
                            let begin = CFAbsoluteTimeGetCurrent()
                            let built = s.makeHash()
                            s.write { s.installHash(built) }
                            self.locked { self.hashMs = (CFAbsoluteTimeGetCurrent() - begin) * 1000 }
                        }
                        let updater = IndexUpdater(config: config)
                        self.onUpdaterCreated?(updater)
                        self.locked { self.updater = updater }
                        self.startWatcher(s, token: token); self.startTimer()
                        // 两种情况立刻写回并换回映射态：旧格式载入的索引常驻堆内存；文件没有可用哈希表时
                        // 表只活在内存里。不补写的话每次启动都要重建 13MB 的表。
                        if !s.read({ s.isFileBacked }) || !carriedTable { self.saveQueue.async { [weak self] in self?.saveChanged(force: true) } }
                        self.scanLatestConfigIfNeeded()
                        if UInt64(Date().timeIntervalSince1970) > s.scanFinishedAt + 7*86400 {
                            self.eventQueue.asyncAfter(deadline: .now()+60) { [weak self] in if let self, self.valid(token) { self.rescan() } }
                        }
                    }
                } else {
                    guard self.valid(token) else { return }
                    let reason = loaded.map { s in
                        s.configFingerprint != self.fingerprint(config) ? "fingerprint" :
                        (self.volumeUUID == nil && s.rootPath != config.rootPath) ? "root" : "cursor"
                    } ?? "missing"
                    Self.log.notice("index load rejected: reason=\(reason, privacy: .public); full scan")
                    self.eventQueue.async { if self.valid(token) { self.setState(.scanning) } }
                    self.scan(config: config, token: token, isRescan: false, uuid: uuid)
                }
            }
        }
    }
    private func scan(config: IndexConfig, token: Int, isRescan: Bool, uuid: String?) {
        guard mountedVolumeMatches(config) else {
            eventQueue.async { if self.valid(token) { self.locked { self.rescanning = false; if !isRescan { self.active = false } }; if !isRescan { self.setState(.idle) } } }
            return
        }
        // Background rebuilds keep spare cores for interactive work; CLI benchmarks can still opt into wider scans.
        // 首次建库保持双线程全速，避免用户久等；后台重建改为单线程 + 吞吐上限，
        // 把 1.2M 目录项的扫描从"一分钟 90% CPU 尖峰"拉平成低占用的长尾任务。
        let scanner = Scanner(config: config, threads: isRescan ? 1 : min(2, ProcessInfo.processInfo.activeProcessorCount))
        if isRescan { scanner.entriesPerSecond = IndexManager.backgroundScanEntriesPerSecond }
        let startId = volumeUUID.flatMap { _ in device(config: config).map(FSWatcher.currentEventId(forDevice:)) } ?? FSWatcher.currentEventId()
        eventQueue.sync {
            guard self.valid(token) else { return }
            self.scanStartEventId = startId
            self.bufferFilterConfig = config
            // A fresh live stream precedes every scan. Replaying the lost historical stream
            // after rebuilding can deliver the same loss again and schedule endless rebuilds.
            let epoch = self.watcherEpoch &+ 1
            let monitor = FSWatcher(paths: [config.rootPath], sinceWhen: UInt64(kFSEventStreamEventIdSinceNow),
                device: self.volumeUUID == nil ? nil : self.device(config: config), queue: self.eventQueue) { [weak self] changes, rescan in
                self?.receiveEvents(changes, mustRescanAll: rescan, token: token, epoch: epoch)
            }
            let watching = monitor.start()
            if watching {
                self.watcherEpoch = epoch
                self.watcher?.stop(); self.watcher = nil; self.scanWatcher?.stop()
                self.scanWatcher = monitor; self.bufferingToken = token
                self.bufferedEvents.removeAll(keepingCapacity: true); self.bufferedEventBytes = 0; self.bufferedRescan = false; self.bufferedLossFlags = 0; self.bufferedOverflow = false
            }
            // Any loss delivered before this scan starts is covered by this scan. Loss on
            // the new stream while scanning is tracked separately and still queues recovery.
            self.recoveryRescanPending = false
            #if DEBUG
            NSLog("Oil Find file scan start: watermark=%llu epoch=%llu fresh=%d", startId, self.watcherEpoch, watching ? 1 : 0)
            #endif
        }
        onScannerCreated?(scanner)
        let proceed = locked { () -> Bool in
            guard active && generation == token else { return false }; currentScanner = scanner; return true
        }
        guard proceed else { return }
        guard var output = scanner.run(), valid(token) else {
            eventQueue.async {
                guard self.valid(token) else { return }
                self.locked { self.currentScanner = nil; self.rescanning = false; if !isRescan { self.active = false } }
                if isRescan {
                    // Preserve the old catalog's replay cursor if opening the scan root failed.
                    if self.unresolvedLossCursor == nil { self.unresolvedLossCursor = self.store.map { store in store.read { store.lastEventId } } ?? startId }
                    _ = self.adoptScanWatcher(token: token)
                    self.recoveryRescanPending = true
                    self.eventQueue.asyncAfter(deadline: .now() + 60) { [weak self] in
                        guard let self, self.valid(token) else { return }; self.startPendingRecovery()
                    }
                } else {
                    self.scanWatcher?.stop(); self.scanWatcher = nil; self.bufferingToken = nil
                    self.bufferedEvents.removeAll(); self.bufferedEventBytes = 0; self.bufferedRescan = false; self.bufferedLossFlags = 0; self.bufferedOverflow = false; self.setState(.idle)
                }
            }; return
        }
        // 消费式建库：扫描缓冲边拷边放，重建峰值不再叠加扫描输出。
        let s = IndexStore(consuming: &output, config: config)
        guard valid(token) else { return }
        s.configFingerprint = fingerprint(config)
        s.scopeFingerprint = scopeFingerprint(config)
        let begin = CFAbsoluteTimeGetCurrent(); s.write { s.buildHash() }
        let ms = (CFAbsoluteTimeGetCurrent()-begin)*1000
        s.lastEventId = startId; s.scanFinishedAt = UInt64(Date().timeIntervalSince1970); s.fsEventsUUID = uuid ?? ""
        eventQueue.async { [weak self] in
            guard let self, self.valid(token) else { return }
            self.watcher?.stop(); self.watcher = nil
            let buffered = Array(self.bufferedEvents.values)
            // UserDropped 只表示本进程没及时取走事件，fseventsd 的历史日志仍完整：从本轮扫描起点回放
            // 就能补齐，不必再整盘重建并整份写盘。内核丢失、ID 回绕、根变化、缓冲溢出或扫描前就有的损失
            // 仍按原路整盘恢复；回放期间若再报丢失，handleEvents 会照常发起重建。
            let replay = self.bufferedRescan && !self.recoveryRescanPending && !self.bufferedOverflow
                && Self.replayableLoss(self.bufferedLossFlags) && self.takeReplayBudget()
            if replay {
                if self.bufferingToken == token { self.scanWatcher?.stop(); self.scanWatcher = nil; self.bufferingToken = nil }
            }
            let adopted = !replay && self.adoptScanWatcher(token: token)
            let lost = !replay && (self.bufferedRescan || self.recoveryRescanPending)
            let updater = IndexUpdater(config: config)
            self.locked { self.updater = updater }
            self.onUpdaterCreated?(updater)
            // Reconcile before publishing. A concurrent save may observe the old safe catalog
            // or the fully prepared replacement, never a cursor temporarily beyond a known gap.
            var batch: ApplySummary?
            if !lost && !buffered.isEmpty { batch = updater.apply(buffered, to: s) }
            guard self.valid(token), !updater.isCancelled else { return }
            let installed = s.read { s.needsCompaction ? s.compacted() : s }
            self.bufferedEvents.removeAll(keepingCapacity: true); self.bufferedEventBytes = 0; self.bufferedRescan = false; self.bufferedLossFlags = 0; self.bufferedOverflow = false
            self.unresolvedLossCursor = lost ? startId : nil
            self.recoveryRescanPending = lost
            if lost {
                self.lossStreak += 1
                let delay = self.lossStreak >= 2 ? min(300 * pow(2, Double(self.lossStreak - 2)), 3600) : 0
                self.recoveryNotBefore = CFAbsoluteTimeGetCurrent() + delay
            } else { self.lossStreak = 0; self.recoveryNotBefore = 0 }
            Self.log.notice("rescan done: entries=\(installed.count) lost=\(lost) replay=\(replay) buffered=\(buffered.count) lossStreak=\(self.lossStreak) backoff=\(Int(max(0, self.recoveryNotBefore - CFAbsoluteTimeGetCurrent())))s")
            self.locked { self.currentStore = installed; self.currentScanner = nil; self.rescanning = false; self.hashMs = ms }
            if let batch {
                let callback = self.locked { self.summary = batch; return self.batchCallback }
                DispatchQueue.main.async { callback?(batch) }
            }
            self.setState(.ready); self.notifyIndex(replaced: true)
            DispatchQueue.global(qos: .utility).async { _ = Pinyin.shared }
            if !adopted { self.startWatcher(installed, token: token) }
            self.saveNow(); self.startTimer()
            self.scanLatestConfigIfNeeded()
            self.startPendingRecovery()
        }
    }
    @discardableResult private func adoptScanWatcher(token: Int) -> Bool {
        guard let monitor = scanWatcher, bufferingToken == token else { return false }
        scanWatcher = nil; watcher = monitor; bufferingToken = nil
        return true
    }
    private func startWatcher(_ s: IndexStore, token: Int) {
        watcherEpoch &+= 1
        let epoch = watcherEpoch
        // 这三个字段由 saveQueue 上的接管在写锁内改写，取快照必须持读锁。
        let snapshot = s.read { (root: s.rootPath, uuid: s.fsEventsUUID, eventId: s.lastEventId) }
        let sinceWhen = volumeUUID != nil && snapshot.uuid.isEmpty ? UInt64(kFSEventStreamEventIdSinceNow) : snapshot.eventId
        let w = FSWatcher(paths: [snapshot.root], sinceWhen: sinceWhen, device: volumeUUID == nil ? nil : device(config: config), queue: eventQueue) { [weak self] changes, rescan in
            self?.receiveEvents(changes, mustRescanAll: rescan, token: token, epoch: epoch)
        }
        watcher = w
        if !w.start() { fputs("Oil Find: cannot start FSEvents\n", stderr) }
    }
    private func receiveEvents(_ changes: [FSChange], mustRescanAll: Bool, token: Int, epoch: UInt64) {
        guard valid(token), epoch == watcherEpoch else {
            #if DEBUG
            if mustRescanAll { NSLog("Oil Find stale file recovery ignored: events=%d min=%llu max=%llu epoch=%llu current=%llu", changes.count, changes.map(\.eventId).min() ?? 0, changes.map(\.eventId).max() ?? 0, epoch, watcherEpoch) }
            #endif
            return
        }
        if mustRescanAll {
            let flags = changes.reduce(UInt32(0)) { $0 | $1.flags }
            Self.log.notice("fsevents loss signal: events=\(changes.count) flags=\(String(flags, radix: 16), privacy: .public) buffering=\(self.bufferingToken != nil)")
        }
        if let monitor = scanWatcher ?? watcher { locked { replayCount = monitor.replayedEventCount; dataPrefix = monitor.reportedDataPrefix } }
        if bufferingToken == token || unresolvedLossCursor != nil {
            // A root loss is not a usable subtree update. The replacement scan handles it;
            // applying it synchronously here would perform another full walk on eventQueue.
            if !mustRescanAll {
                let filter = bufferFilterConfig ?? config
                for change in changes {
                    if !IndexUpdater.mayAffectIndex(change.path, config: filter) { continue }
                    if var existing = bufferedEvents[change.path] {
                        existing.flags |= change.flags; existing.eventId = max(existing.eventId, change.eventId)
                        bufferedEvents[change.path] = existing
                    } else {
                        let cost = change.path.utf8.count + 96
                        if cost > bufferedEventByteLimit - bufferedEventBytes {
                            if !bufferedOverflow { Self.log.notice("event buffer overflow: paths=\(self.bufferedEvents.count) bytes=\(self.bufferedEventBytes)") }
                            bufferedRescan = true; bufferedOverflow = true; continue
                        }
                        bufferedEvents[change.path] = change; bufferedEventBytes += cost
                    }
                }
            }
            bufferedRescan = bufferedRescan || mustRescanAll
            if mustRescanAll { bufferedLossFlags |= changes.reduce(UInt32(0)) { $0 | $1.flags } }
            onBufferedEvents?(changes)
            #if DEBUG
            if mustRescanAll { NSLog("Oil Find buffered file recovery: events=%d min=%llu max=%llu watermark=%llu epoch=%llu", changes.count, changes.map(\.eventId).min() ?? 0, changes.map(\.eventId).max() ?? 0, scanStartEventId, epoch) }
            #endif
        } else { handleEvents(changes, mustRescanAll: mustRescanAll) }
    }
    // Test injection and FSEvents share the event-queue implementation, including stream identity.
    internal func injectEvents(_ changes: [FSChange], mustRescanAll: Bool, watcherEpoch: UInt64? = nil) {
        eventQueue.async { [weak self] in
            guard let self, self.locked({ self.active }) else { return }
            self.receiveEvents(changes, mustRescanAll: mustRescanAll, token: self.locked { self.generation }, epoch: watcherEpoch ?? self.watcherEpoch)
        }
    }
    private func handleEvents(_ changes: [FSChange], mustRescanAll: Bool) {
        if mustRescanAll {
            #if DEBUG
            let flags = Set(changes.map { String($0.flags, radix: 16) }).sorted().joined(separator: ",")
            NSLog("Oil Find file recovery: events=%d flags=%@ pending=%d min=%llu max=%llu watermark=%llu epoch=%llu", changes.count, flags, isRescanning ? 1 : 0, changes.map(\.eventId).min() ?? 0, changes.map(\.eventId).max() ?? 0, scanStartEventId, watcherEpoch)
            #endif
            // 已排定的回放从已应用游标重放，覆盖这次丢件，不再消耗预算。
            if replayPending, !isRescanning { return }
            // 实时流被丢件：先从已应用游标重放历史补齐，省掉一次整盘重建与整份写盘。
            if !isRescanning, self.store != nil, Self.replayableLoss(changes.reduce(UInt32(0)) { $0 | $1.flags }), takeReplayBudget() {
                let delay = nextReplayDelay, token = locked { generation }
                Self.log.notice("live loss: replaying history from applied cursor in \(delay, format: .fixed(precision: 1))s")
                // 停流并作废已排队的旧投递；游标不前进，回放会把它们重新送到。
                watcher?.stop(); watcher = nil; watcherEpoch &+= 1
                let epoch = watcherEpoch
                replayPending = true
                eventQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else { return }
                    self.replayPending = false
                    guard self.valid(token), !self.isRescanning,
                          self.watcher == nil, epoch == self.watcherEpoch, let store = self.store else { return }
                    self.startWatcher(store, token: token)
                }
                return
            }
            if unresolvedLossCursor == nil { unresolvedLossCursor = self.store.map { store in store.read { store.lastEventId } } }
            if isRescanning { recoveryRescanPending = true }
            else { beginRescan(reason: "lost-events") }
            return
        }
        guard !changes.isEmpty, let store = self.store, let updater = locked({ self.updater }) else { return }
        let result = updater.apply(changes, to: store)
        guard !updater.isCancelled else { return }
        let callback = locked { self.summary = result; return batchCallback }
        DispatchQueue.main.async { callback?(result) }
        if store.read({ store.needsCompaction }) {
            // The event queue is the sole writer; readers may continue during copying.
            let compact = store.read { store.compacted() }
            locked { currentStore = compact }; notifyIndex(replaced: true)
            // 压实结果落盘并换回映射态，避免旧索引与新索引同时常驻堆内存。
            saveQueue.async { [weak self] in self?.saveChanged() }
        } else { notifyIndex(replaced: false) }
    }
    public func explain(path: String) -> CoverageExplanation {
        let config = DispatchQueue.getSpecific(key: eventKey) == true ? self.config : eventQueue.sync { self.config }
        return Coverage.explain(path: path, config: config, store: store)
    }
    public func rescan() {
        eventQueue.async { [weak self] in
            self?.beginRescan()
        }
    }
    public func updateConfig(_ config: IndexConfig) {
        eventQueue.async { [weak self] in
            guard let self, self.fingerprint(self.config) != self.fingerprint(config) else { return }
            self.config = config
            if let values = self.settingsDefaults?.stringArray(forKey: "excludedExtensions") { self.config.excludedExtensions = Set(values) }
            if self.locked({ self.offline }) { self.reloadOffline() }
            else { self.beginRescan() }
        }
    }
    private func scanLatestConfigIfNeeded() {
        if store?.configFingerprint != fingerprint(config) { beginRescan(reason: "fingerprint-change") }
    }
    private func beginRescan(reason: String = "requested") {
        let token: Int? = locked {
            guard active && !offline && currentState == .ready && !rescanning else { return nil }
            rescanning = true; return generation
        }
        guard let token else { return }
        Self.log.notice("rescan begin: reason=\(reason, privacy: .public) lossStreak=\(self.lossStreak)")
        let config = self.config
        onRescanStart?()
        scanQueue.async { [weak self] in
            if let self, self.valid(token) {
                self.scan(config: config, token: token, isRescan: true, uuid: self.deviceUUID(config: config))
            }
        }
    }
    private func startPendingRecovery() {
        guard recoveryRescanPending, !isRescanning else { return }
        let wait = recoveryNotBefore - CFAbsoluteTimeGetCurrent()
        if wait > 0 {
            // 退避期间损失仍未解决：事件继续只进缓冲，旧索引照常服务搜索。
            guard !recoveryDeferred else { return }
            recoveryDeferred = true
            eventQueue.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self else { return }
                self.recoveryDeferred = false; self.startPendingRecovery()
            }
            return
        }
        recoveryRescanPending = false
        beginRescan(reason: "recovery")
    }
    private func notifyIndex(replaced: Bool) {
        let now = CFAbsoluteTimeGetCurrent()
        if replaced || now-lastNotification >= 1 {
            pendingNotification?.cancel(); pendingNotification = nil; lastNotification = now
            let callback = locked { indexCallback }; DispatchQueue.main.async { callback?() }
        } else if pendingNotification == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.locked({ self.active }) else { return }
                self.pendingNotification = nil; self.notifyIndex(replaced: false)
            }
            pendingNotification = work; eventQueue.asyncAfter(deadline: .now() + (1-(now-lastNotification)), execute: work)
        }
    }
    private func startTimer() {
        if timer != nil { return }
        let timer = DispatchSource.makeTimerSource(queue: eventQueue)
        timer.schedule(deadline: .now()+1800, repeating: 1800)
        timer.setEventHandler { [weak self] in self?.saveQueue.async { [weak self] in self?.saveChanged(periodic: true) } }
        self.timer = timer; timer.resume()
    }
    private var adoptionRetries = 0
    /// fseventsd 清空日志换新 UUID 后（本机实测一天 7 次），实时流照常投递，落盘游标却仍挂在旧 UUID 上，
    /// 下次启动只能整盘重建。首次看到新 UUID 时记下当时的全局事件 ID：新日志从清空那一刻开始，
    /// 不晚于这个 ID。已应用游标越过它，此后的事件就都在新日志里，保存时改记新 UUID，重启即可回放。
    /// 只用于启动盘：外置卷的按设备事件 ID 会滞后，拿它当界限不安全。只在 saveQueue 上读写。
    private var observedUUID: (uuid: String, eventId: UInt64)?
    /// 测试注入点：按索引根取 fseventsd 当前 UUID，以及全局当前事件 ID。
    internal var currentFSEventsUUID: (String) -> String? = { root in
        var st = stat(); guard stat(root == "/" ? "/System/Volumes/Data" : root, &st) == 0 else { return nil }
        return FSWatcher.uuid(forDevice: st.st_dev)
    }
    internal var currentGlobalEventId: () -> UInt64 = { FSWatcher.currentEventId() }
    /// 新 UUID 只改内存里的 store，不为此单独整份落盘：随下一次本来就要做的保存（定时、退出）写入。
    /// - Returns: 是否改记了新 UUID。
    @discardableResult private func adoptRotatedFSEventsUUID(_ s: IndexStore) -> Bool {
        guard volumeUUID == nil, !locked({ rescanning }) else { return false }
        let (root, stored, cursor) = s.read { (s.rootPath, s.fsEventsUUID, s.lastEventId) }
        guard !stored.isEmpty, let current = currentFSEventsUUID(root), !current.isEmpty else { return false }
        guard stored != current else { observedUUID = nil; return false }
        guard let observed = observedUUID, observed.uuid == current else {
            observedUUID = (current, currentGlobalEventId())
            Self.log.notice("fsevents uuid rotated; adopt after cursor passes \(self.observedUUID!.eventId)")
            return false
        }
        guard cursor >= observed.eventId else { return false }
        s.write { if s.fsEventsUUID == stored && s.lastEventId >= observed.eventId { s.fsEventsUUID = current } }
        observedUUID = nil
        Self.log.notice("fsevents uuid adopted at cursor \(cursor)")
        return true
    }
    private func saveChanged(force: Bool = false, periodic: Bool = false) {
        guard !locked({ offline }), let s = store else { return }
        adoptRotatedFSEventsUUID(s)
        let (version, mutations, fileBacked) = s.read { (s.version, s.mutationCount, s.isFileBacked) }
        if !force, savedStore === s, savedVersion == version { return }
        // 定时保存只在必要时整份重写：有堆段（内存要靠落盘接管归还）、改动累计较多或距上次落盘过久。
        if periodic, savedStore === s, fileBacked, mutations &- savedMutations < Self.periodicSaveMutations,
           CFAbsoluteTimeGetCurrent() - savedAt < Self.periodicSaveMaxAge { return }
        do {
            // The saved version is captured under the same read lock as the file snapshot.
            let saved = try s.saveSnapshot(to: dbURL.path)
            savedStore = s; savedVersion = saved.version
            savedMutations = saved.mutations; savedAt = CFAbsoluteTimeGetCurrent()
            adoptSavedMapping(s, saved: saved.version, mutations: saved.mutations)
        } catch { fputs("Oil Find: save failed: \(error)\n", stderr) }
    }
    /// 落盘成功后把内存里的索引换回文件映射：同一个 store 对象原地接管刚写好的文件，
    /// 身份与 version 不变，堆段归还系统，索引页变回不计入物理内存的干净文件页。
    /// 因此搜索缓存、UI 选择态与来源绑定都不需要失效，也不需要额外通知。
    private func adoptSavedMapping(_ s: IndexStore, saved: UInt64, mutations: UInt64) {
        guard let mapped = IndexStore.load(from: dbURL.path) else { scheduleAdoptRetry(s); return }
        if s.adoptMapping(from: mapped, expectedVersion: saved, expectedMutations: mutations) { adoptionRetries = 0; return }
        // 落盘那几百毫秒里索引又被改动，文件已落后一版，这次不接管。
        scheduleAdoptRetry(s)
    }
    /// 接管失败后堆段会一直留到下一次改动（可能很久），所以要再存一次把映射换进来。
    /// 但索引还在写时不重存：改动路径自己会触发下一次保存与接管，在这里反复整份写盘只是白费 IO。
    /// 于是先记下观察点，3 秒后确认索引已安静再重存；仍在动就顺延，重试有上限。
    private func scheduleAdoptRetry(_ s: IndexStore) {
        guard adoptionRetries < 3 else { return }
        adoptionRetries += 1
        let mark = s.read { (version: s.version, mutations: s.mutationCount) }
        saveQueue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, let current = self.store, current === s, !current.read({ current.isFileBacked }) else { return }
            let now = current.read { (version: current.version, mutations: current.mutationCount) }
            guard now.version == mark.version, now.mutations == mark.mutations else { self.scheduleAdoptRetry(s); return }
            self.saveChanged(force: true)
        }
    }
    public func saveNow() {
        if DispatchQueue.getSpecific(key: saveKey) == true { saveChanged() }
        else { saveQueue.sync { saveChanged() } }
    }
    public func stop() {
        let resources = locked { (currentScanner, updater) }
        let scanner = resources.0
        scanner?.cancel(); resources.1?.cancel()
        let stopEvents = {
            let pending = self.locked { () -> (Scanner?, IndexUpdater?) in
                let pending = (self.currentScanner, self.updater)
                self.active = false; self.generation += 1; self.currentScanner = nil; self.updater = nil; self.rescanning = false
                return pending
            }
            pending.0?.cancel(); pending.1?.cancel()
            self.recoveryRescanPending = false; self.unresolvedLossCursor = nil; self.lossStreak = 0; self.recoveryNotBefore = 0
            self.watcherEpoch &+= 1
            self.watcher?.stop(); self.watcher = nil
            self.scanWatcher?.stop(); self.scanWatcher = nil; self.bufferingToken = nil; self.bufferedEvents.removeAll(); self.bufferedEventBytes = 0; self.bufferedRescan = false; self.bufferedLossFlags = 0; self.bufferedOverflow = false
            self.timer?.cancel(); self.timer = nil; self.pendingNotification?.cancel(); self.pendingNotification = nil
            self.setState(.idle)
        }
        if DispatchQueue.getSpecific(key: eventKey) == true { stopEvents() } else { eventQueue.sync(execute: stopEvents) }
        // Jobs publish only through the generation-checked event queue. Cancellation
        // releases directory handles without waiting for a discarded store build.
        saveNow()
    }
}
