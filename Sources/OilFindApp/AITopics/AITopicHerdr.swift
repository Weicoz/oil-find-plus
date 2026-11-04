import AppKit
import Foundation

/// Which surface an AI topic opens in.
enum AITopicOpenTarget: String, CaseIterable {
    case herdr, app
    static let defaultsKey = "aiTopicsOpenTarget"
    var labelKey: String { self == .herdr ? "topicsOpenHerdrPreferred" : "topicsOpenAlwaysApp" }
}

/// Bridges AI topics to running Herdr panes.
///
/// Herdr owns the panes, so its CLI is the only stable interface: `agent list` reports every
/// running agent with its pane, session UUID and working directory, and `agent focus` moves the
/// server-side focus. Herdr's GUI host does not follow that focus on its own, so the caller raises
/// it afterwards.
enum AITopicHerdr {
    struct Agent: Equatable {
        let paneID: String
        let name: String
        let session: String?
        let cwd: String
        let foregroundCwd: String
        let title: String
        let focused: Bool
    }

    /// GUI terminals Herdr can run inside; used only when the server process cannot be inspected.
    /// Focusing a pane never raises the host by itself, so the caller must activate its application.
    static let knownHostBundleIdentifiers = [
        "com.muxy.app", "com.cmuxterm.app", "com.apple.Terminal",
        "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm"
    ]
    /// `herdr agent list` answers over a local socket; anything slower means the server is stuck.
    static let commandTimeout: TimeInterval = 1.5
    private static let cacheLifetime: TimeInterval = 3
    private static let hostLock = NSLock()
    private static var hostResolved = false
    private static var cachedHostBundle: String?

    // MARK: - Discovery

    static func executable(environment: [String: String] = ProcessInfo.processInfo.environment,
                           home: String = NSHomeDirectory(), fileManager: FileManager = .default) -> String? {
        if let override = environment["OILFIND_HERDR_BIN"], !override.isEmpty,
           fileManager.isExecutableFile(atPath: override) { return override }
        for path in ["\(home)/.local/bin/herdr", "/opt/homebrew/bin/herdr", "/usr/local/bin/herdr"]
        where fileManager.isExecutableFile(atPath: path) { return path }
        return nil
    }

    static func parse(_ data: Data) -> [Agent] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let entries = result["agents"] as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let pane = entry["pane_id"] as? String, !pane.isEmpty else { return nil }
            let session = (entry["agent_session"] as? [String: Any])?["value"] as? String
            let title = (entry["terminal_title_stripped"] as? String) ?? (entry["terminal_title"] as? String) ?? ""
            return Agent(paneID: pane, name: entry["agent"] as? String ?? "",
                         session: session.flatMap { $0.isEmpty ? nil : $0 },
                         cwd: entry["cwd"] as? String ?? "",
                         foregroundCwd: entry["foreground_cwd"] as? String ?? "",
                         title: title, focused: entry["focused"] as? Bool ?? false)
        }
    }

    // MARK: - Matching

    /// Matches a topic to a live pane. The session UUID is authoritative. Codex reports no session,
    /// so those panes fall back to agent kind, project directory and a whole title segment.
    ///
    /// A pane that reports a *different* session is running another conversation, so it never matches
    /// even when the directory and a repeated auto-title agree; a wrong jump is worse than no jump.
    static func pane(for topic: AITopic, in agents: [Agent]) -> String? {
        let identifier = topic.id.lowercased()
        if !identifier.isEmpty, let exact = agents.first(where: { $0.session?.lowercased() == identifier }) {
            return exact.paneID
        }
        let project = canonical(topic.project)
        let title = topic.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !project.isEmpty, title.count >= 3 else { return nil }
        let provider = topic.provider.rawValue.lowercased()
        return agents.first { agent in
            agent.session == nil
                && agent.name.lowercased().contains(provider)
                && (canonical(agent.cwd) == project || canonical(agent.foregroundCwd) == project)
                && segments(of: agent.title).contains(title)
        }?.paneID
    }

    /// Herdr pane titles combine the running task with its project, for example a task then a pipe then a project.
    private static func segments(of title: String) -> [String] {
        title.split(whereSeparator: { $0 == "|" || $0 == "\u{00b7}" || $0 == "\u{2014}" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    private static func canonical(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let standard = (trimmed as NSString).expandingTildeInPath as NSString
        let resolved = standard.standardizingPath
        return resolved.count > 1 && resolved.hasSuffix("/") ? String(resolved.dropLast()) : resolved
    }

    // MARK: - Cache

    private static let lock = NSLock()
    private static var cached: (agents: [Agent], at: Date)?
    private static var refreshing = false

    /// Returns cached agents without spawning a process, so menus can ask for free.
    static func cachedAgents(now: Date = Date()) -> [Agent] {
        cachedAgentsIfFresh(now: now) ?? []
    }

    private static func cachedAgentsIfFresh(now: Date = Date()) -> [Agent]? {
        lock.lock(); defer { lock.unlock() }
        guard let cached, now.timeIntervalSince(cached.at) < cacheLifetime else { return nil }
        return cached.agents
    }

    /// Last known agents for display, including a stale snapshot; kicks a background refresh when stale.
    /// Stale rows only affect ordering and the Herdr capsule; opening a stale pane fails visibly.
    static func displayAgents(now: Date = Date()) -> [Agent] {
        lock.lock()
        let snapshot = cached
        let stale = snapshot.map { now.timeIntervalSince($0.at) >= cacheLifetime } ?? true
        lock.unlock()
        if stale { refresh() }
        return snapshot?.agents ?? []
    }

    /// Agents for list-style results. Waits for at most one CLI call and refreshes the shared cache.
    static func liveAgents(timeout: TimeInterval = commandTimeout) -> [Agent] {
        if let fresh = cachedAgentsIfFresh() { return fresh }
        guard let agents = list(timeout: timeout) else { return cachedAgentsIfFresh() ?? [] }
        lock.lock(); cached = (agents, Date()); lock.unlock()
        return agents
    }

    static func cachedPane(for topic: AITopic, now: Date = Date()) -> String? {
        let agents = cachedAgents(now: now)
        return agents.isEmpty ? nil : pane(for: topic, in: agents)
    }

    /// Refreshes the cache off the main thread; repeated calls inside the lifetime are no-ops.
    static func refresh(force: Bool = false) {
        lock.lock()
        let fresh = cached.map { Date().timeIntervalSince($0.at) < cacheLifetime } ?? false
        if refreshing || (fresh && !force) { lock.unlock(); return }
        refreshing = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            let agents = list()
            lock.lock()
            if let agents { cached = (agents, Date()) }
            refreshing = false
            lock.unlock()
        }
    }

    // MARK: - Actions

    /// Runs `herdr agent list`; nil means Herdr is missing, stuck or unhappy.
    static func list(binary: String? = nil, timeout: TimeInterval = commandTimeout) -> [Agent]? {
        guard let binary = binary ?? executable(),
              let output = run(binary, ["agent", "list"], timeout: timeout), output.status == 0 else { return nil }
        return parse(output.data)
    }

    /// Focuses the pane that runs `topic`, if any.
    static func focus(_ topic: AITopic, binary: String? = nil, timeout: TimeInterval = commandTimeout) -> Bool {
        guard let binary = binary ?? executable(), let agents = list(binary: binary, timeout: timeout),
              let pane = pane(for: topic, in: agents) else { return false }
        return focus(pane: pane, binary: binary, timeout: timeout)
    }

    @discardableResult
    static func focus(pane: String, binary: String? = nil, timeout: TimeInterval = commandTimeout) -> Bool {
        guard let binary = binary ?? executable() else { return false }
        return run(binary, ["agent", "focus", pane], timeout: timeout)?.status == 0
    }

    /// Brings the Herdr host window forward; focusing a pane does not raise it.
    @discardableResult
    static func raiseHost() -> Bool {
        guard let identifier = hostBundleIdentifier() else { return false }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first {
            return running.activate(from: .current, options: [.activateAllWindows])
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
        return true
    }

    // MARK: - Host

    /// Resolves the application that owns the running Herdr server.
    ///
    /// Herdr is host agnostic: Muxy, cmux, Terminal and other GUI terminals all run the same server.
    /// The server inherits its launcher's environment and process ancestry, so `__CFBundleIdentifier`
    /// or the first GUI ancestor identifies the host without hard-coding Muxy. Results are cached
    /// because the caller raises the host on the main thread.
    static func hostBundleIdentifier(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let override = environment["OILFIND_HERDR_HOST_BUNDLE"], !override.isEmpty { return override }
        hostLock.lock()
        defer { hostLock.unlock() }
        if hostResolved { return cachedHostBundle }
        let resolved = discoverHostBundleIdentifier()
        cachedHostBundle = resolved
        hostResolved = resolved != nil
        return resolved
    }

    private static func discoverHostBundleIdentifier() -> String? {
        // A running server with no GUI ancestor is headless; raising an unrelated terminal would lie.
        if let pid = serverProcessIdentifier() { return bundleIdentifier(ofServer: pid) }
        return knownHostBundleIdentifiers.first {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
        }
    }

    /// The Herdr server holds the socket open; `lsof` names it without relying on process titles.
    private static func serverProcessIdentifier() -> pid_t? {
        guard let output = run("/usr/sbin/lsof", ["-U"], timeout: commandTimeout),
              output.status == 0, let text = String(data: output.data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.contains("herdr.sock") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count > 1, fields[0] == "herdr" || fields[0].hasSuffix("herdr"),
                  let pid = pid_t(fields[1]), processArguments(pid).contains("server") else { continue }
            return pid
        }
        return nil
    }

    private static func processArguments(_ pid: pid_t) -> String {
        guard let output = run("/bin/ps", ["-p", String(pid), "-o", "command="], timeout: commandTimeout),
              output.status == 0 else { return "" }
        return String(decoding: output.data, as: UTF8.self)
    }

    private static func bundleIdentifier(ofServer pid: pid_t) -> String? {
        if let bundle = environment(ofProcess: pid)?["__CFBundleIdentifier"], !bundle.isEmpty {
            return bundle
        }
        var current = pid
        for _ in 0 ..< 8 {
            guard let parent = parentIdentifier(of: current), parent > 1 else { break }
            if let application = NSRunningApplication(processIdentifier: parent),
               let bundle = application.bundleIdentifier { return bundle }
            current = parent
        }
        return nil
    }

    /// `ps eww` prints the environment after the command, separated by spaces.
    private static func environment(ofProcess pid: pid_t) -> [String: String]? {
        guard let output = run("/bin/ps", ["eww", "-p", String(pid)], timeout: commandTimeout),
              output.status == 0, let text = String(data: output.data, encoding: .utf8) else { return nil }
        var values: [String: String] = [:]
        for token in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            guard let equals = token.firstIndex(of: "=") else { continue }
            let key = String(token[..<equals])
            let value = String(token[token.index(after: equals)...])
            if !key.isEmpty, !value.isEmpty { values[key] = value }
        }
        return values
    }

    private static func parentIdentifier(of pid: pid_t) -> pid_t? {
        guard let output = run("/bin/ps", ["-p", String(pid), "-o", "ppid="], timeout: commandTimeout),
              output.status == 0, let text = String(data: output.data, encoding: .utf8) else { return nil }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Process

    private final class Output { var data = Data() }

    static func run(_ binary: String, _ arguments: [String], timeout: TimeInterval,
                    environment inherited: [String: String]? = nil) -> (data: Data, status: Int32)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        // A nested Herdr session must not inherit the caller's pane identity.
        var environment = inherited ?? ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("HERDR_") { environment.removeValue(forKey: key) }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return nil }
        // Read to EOF before waiting, otherwise a full pipe deadlocks the child.
        let box = Output(), done = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "com.oiloil.find.herdr.output")
        queue.async { box.data = pipe.fileHandleForReading.readDataToEndOfFile(); done.signal() }
        guard done.wait(timeout: .now() + timeout) == .success else { process.terminate(); return nil }
        process.waitUntilExit()
        var data = Data()
        queue.sync { data = box.data }
        return (data, process.terminationStatus)
    }
}
