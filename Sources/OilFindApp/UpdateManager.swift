import AppKit
import OilFindCore

enum UpdateState: Equatable {
    case idle, checking, available, downloading(Double), installing, latest, failed(UpdateFailure)
    var busy: Bool {
        switch self { case .checking, .downloading, .installing: return true; default: return false }
    }
    var installing: Bool {
        switch self { case .downloading, .installing: return true; default: return false }
    }
}

final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()
    static var current: UpdateVersion {
        UpdateVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.3.0",
                      build: Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "7") ?? 7)
            ?? UpdateVersion("1.3.0", build: 7)!
    }
    @Published private(set) var state: UpdateState = .idle
    @Published private(set) var manifest: UpdateManifest?
    @Published var automatic: Bool { didSet { if !snapshot { preferences.automatic = automatic; reschedule() } } }
    var onChange: (() -> Void)?
    private let preferences: UpdatePreferences
    let runningVersion: UpdateVersion
    private let snapshot: Bool
    private var timer: Timer?
    private var windowController: UpdateWindowController?
    private var started = false
    private var readyToRelaunch = false
    private var retryDelay = UpdatePreferences.retryInterval
    var preventsTermination: Bool { state.installing && !readyToRelaunch }
    var canCheck: Bool {
        #if DEBUG
        return false
        #else
        return !state.busy
        #endif
    }
    init(snapshot: Bool = false, preferences: UpdatePreferences = UpdatePreferences(), current: UpdateVersion = UpdateManager.current) {
        self.snapshot = snapshot; self.preferences = preferences
        runningVersion = current
        automatic = snapshot ? true : preferences.automatic
    }
    /// Delay before the first automatic check after launch.
    static let launchDelay: TimeInterval = 30
    func start() {
        #if !DEBUG
        started = true; reschedule()
        #endif
    }
    func stop() { timer?.invalidate(); timer = nil; started = false }
    /// Schedules the next check from the persisted last successful one, so relaunching the app
    /// several times a day does not ask the server again.
    private func reschedule() { schedule(delay: max(Self.launchDelay, preferences.secondsUntilNextCheck())) }
    private func schedule(delay: TimeInterval) {
        timer?.invalidate(); timer = nil
        guard started, automatic else { return }
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.automaticCheck()
        }
    }
    /// Failed checks back off from one hour up to the regular daily cadence.
    private func scheduleAfter(reached: Bool) {
        guard reached else {
            schedule(delay: retryDelay)
            retryDelay = min(retryDelay * 2, UpdatePreferences.checkInterval)
            return
        }
        retryDelay = UpdatePreferences.retryInterval
        schedule(delay: UpdatePreferences.checkInterval)
    }
    private func automaticCheck() {
        guard started, automatic else { return }
        run(manual: false) { [weak self] reached in self?.scheduleAfter(reached: reached) }
    }
    func check(manual: Bool = true) {
        run(manual: manual) { [weak self] reached in
            guard manual else { return }
            self?.scheduleAfter(reached: reached)
        }
    }
    private func run(manual: Bool, completion: @escaping (Bool) -> Void) {
        #if DEBUG
        completion(false)
        #else
        guard !snapshot, !state.busy else { completion(false); return }
        setState(.checking)
        Task { @MainActor in
            do {
                let latest = try await UpdateClient(version: Self.current.version.text).check()
                preferences.recordCheck()
                if preferences.shouldOffer(latest, current: Self.current, system: ProcessInfo.processInfo.operatingSystemVersion, manual: manual) {
                    manifest = latest; setState(.available); present()
                } else if manual {
                    manifest = nil; setState(.latest); present()
                } else {
                    setState(manifest == nil ? .idle : .available)
                }
                completion(true)
            } catch {
                if manual { setState(.failed((error as? UpdateFailure) ?? .other)); present() }
                else { setState(manifest == nil ? .idle : .available) }
                completion(false)
            }
        }
        #endif
    }
    func present() {
        if windowController == nil { windowController = UpdateWindowController(model: self) }
        NSApp.activate(ignoringOtherApps: true)
        windowController?.present()
    }
    func dismiss() { windowController?.close() }
    func skip() {
        guard let manifest, !state.busy else { return }
        if !snapshot { preferences.skip(manifest) }
        self.manifest = nil; setState(.idle); dismiss()
    }
    func install() {
        #if !DEBUG
        guard let manifest, !state.busy, !snapshot else { return }
        readyToRelaunch = false
        setState(.downloading(0))
        let current = Self.current, application = Bundle.main.bundleURL
        Task { @MainActor in
            var archive: URL?
            defer { if let archive { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) } }
            do {
                let client = UpdateClient(version: current.version.text)
                let downloaded = try await client.download(manifest) { [weak self] fraction in
                    DispatchQueue.main.async {
                        if case .downloading = self?.state { self?.setState(.downloading(fraction)) }
                    }
                }
                archive = downloaded; setState(.installing)
                let installation = try await Task.detached(priority: .utility) {
                    try UpdateInstaller(application: application, current: current).install(archive: downloaded, manifest: manifest)
                }.value
                // NSApplication.terminate can exit without unwinding the async task.
                try? FileManager.default.removeItem(at: downloaded.deletingLastPathComponent())
                archive = nil
                do { try UpdateRelauncher().startWaiting(for: ProcessInfo.processInfo.processIdentifier, installation: installation) }
                catch {
                    try UpdateInstaller(application: application, current: current).rollback(installation)
                    throw UpdateFailure.other
                }
                readyToRelaunch = true
                NSApp.terminate(nil)
            } catch { setState(.failed((error as? UpdateFailure) ?? .other)) }
        }
        #endif
    }
    func openWebsite() { NSWorkspace.shared.open(URL(string: "https://github.com/Weicoz/oil-find-plus")!) }
    func reportLaunchFailure(_ failure: UpdateFailure) { setState(.failed(failure)); present() }
    private func setState(_ value: UpdateState) { state = value; onChange?() }
    var menuTitle: String {
        switch state {
        case .downloading(let fraction): return L10n.text("update.downloading", Self.percent(fraction))
        case .installing: return L10n.text("update.installing")
        default: return manifest.map { L10n.text("update.menuAvailable", $0.version) } ?? L10n.text("update.check")
        }
    }
    static func percent(_ fraction: Double) -> String { "\(Int(fraction * 100))%" }
    #if DEBUG
    func prepareSnapshot(_ state: UpdateState, manifest: UpdateManifest?) { self.manifest = manifest; setState(state) }
    #endif
    deinit { timer?.invalidate() }
}
