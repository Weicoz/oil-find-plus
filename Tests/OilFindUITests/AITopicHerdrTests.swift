import AppKit
import XCTest
@testable import OilFindApp

final class AITopicHerdrTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oilfind-herdr-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func script(_ body: String, in root: URL) throws -> String {
        let url = root.appendingPathComponent("herdr-" + UUID().uuidString)
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }
    private func topic(_ provider: AITopicProvider, id: String, project: String, title: String = "") -> AITopic {
        AITopic(id: id, provider: provider, title: title, project: project)
    }
    private let payload = """
    {"id":"cli:agent:list","result":{"agents":[
      {"agent":"claude","agent_session":{"agent":"claude","kind":"id","source":"herdr:claude","value":"18CA3D84-F5D6-4CC9-8C5B-EFD6B0EBACFB"},"cwd":"/Users/dev/project-a","focused":false,"foreground_cwd":"/Users/dev/project-a","pane_id":"wK:p3W","terminal_title":"claude: project-a","terminal_title_stripped":"project-a"},
      {"agent":"codex","agent_session":null,"cwd":"/Users/dev/project-b","focused":true,"foreground_cwd":"/Users/dev/project-b/sub","pane_id":"wS:p1","terminal_title_stripped":"codex: project-b"},
      {"agent":"codex","cwd":"/Users/dev/project-b","focused":false,"pane_id":"wN:p2","terminal_title_stripped":"scratch | project-b"}
    ]}}
    """
    private func agents() -> [AITopicHerdr.Agent] { AITopicHerdr.parse(Data(payload.utf8)) }

    func testParseReadsPanesSessionsAndWorkingDirectories() {
        let agents = agents()
        XCTAssertEqual(agents.count, 3)
        XCTAssertEqual(agents[0].paneID, "wK:p3W")
        XCTAssertEqual(agents[0].session, "18CA3D84-F5D6-4CC9-8C5B-EFD6B0EBACFB")
        XCTAssertEqual(agents[0].cwd, "/Users/dev/project-a")
        XCTAssertEqual(agents[0].title, "project-a")
        XCTAssertFalse(agents[0].focused)
        XCTAssertNil(agents[1].session)
        XCTAssertTrue(agents[1].focused)
    }
    func testParseRejectsPayloadsWithoutUsableAgents() {
        XCTAssertTrue(AITopicHerdr.parse(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(AITopicHerdr.parse(Data(#"{"result":{"agents":[{"agent":"claude"}]}}"#.utf8)).isEmpty)
        XCTAssertTrue(AITopicHerdr.parse(Data(#"{"id":"cli:agent:list"}"#.utf8)).isEmpty)
    }
    func testSessionIdentifierMatchesRegardlessOfCase() {
        let topic = topic(.claude, id: "18ca3d84-f5d6-4cc9-8c5b-efd6b0ebacfb", project: "/elsewhere")
        XCTAssertEqual(AITopicHerdr.pane(for: topic, in: agents()), "wK:p3W")
    }
    func testCodexMatchesAgentKindDirectoryAndWholeTitleSegment() {
        let matching = topic(.codex, id: UUID().uuidString, project: "/Users/dev/project-b", title: "codex: project-b")
        XCTAssertEqual(AITopicHerdr.pane(for: matching, in: agents()), "wS:p1")
        // The title of an unfocused pane still wins over a focused sibling in the same directory.
        let titled = topic(.codex, id: UUID().uuidString, project: "/Users/dev/project-b", title: "scratch")
        XCTAssertEqual(AITopicHerdr.pane(for: titled, in: agents()), "wN:p2")
        // No session and no title leaves nothing to identify the pane, so no jump is offered.
        let plain = topic(.codex, id: UUID().uuidString, project: "/Users/dev/project-b")
        XCTAssertNil(AITopicHerdr.pane(for: plain, in: agents()))
        // A Claude topic never borrows a Codex pane, even inside the same directory.
        let crossKind = topic(.claude, id: UUID().uuidString, project: "/Users/dev/project-b", title: "scratch")
        XCTAssertNil(AITopicHerdr.pane(for: crossKind, in: agents()))
    }
    func testPaneRunningAnotherSessionNeverMatchesByDirectoryOrTitle() {
        let shared = #"{"result":{"agents":[{"agent":"claude","agent_session":{"value":"b1ec2521-0000-0000-0000-000000000001"},"cwd":"/Users/dev/project-a","pane_id":"wK:p3W","terminal_title_stripped":"agit: unnamed"}]}}"#
        let panes = AITopicHerdr.parse(Data(shared.utf8))
        // Same directory and the same repeated auto-title, but an older session: no jump.
        let older = topic(.claude, id: "6732b81f-0000-0000-0000-000000000002", project: "/Users/dev/project-a", title: "agit: unnamed")
        XCTAssertNil(AITopicHerdr.pane(for: older, in: panes))
        // The session UUID outranks the directory, so a moved session still matches.
        let same = topic(.claude, id: "B1EC2521-0000-0000-0000-000000000001", project: "/elsewhere", title: "unrelated")
        XCTAssertEqual(AITopicHerdr.pane(for: same, in: panes), "wK:p3W")
    }
    func testTitleMustMatchAWholeSegment() {
        let payload = #"{"result":{"agents":[{"agent":"codex","cwd":"/Users/dev/herdr-ios","pane_id":"wN:p1","terminal_title_stripped":"Ask Matt | herdr-ios"}]}}"#
        let panes = AITopicHerdr.parse(Data(payload.utf8))
        XCTAssertEqual(AITopicHerdr.pane(for: topic(.codex, id: UUID().uuidString, project: "/Users/dev/herdr-ios", title: "Ask Matt"), in: panes), "wN:p1")
        XCTAssertEqual(AITopicHerdr.pane(for: topic(.codex, id: UUID().uuidString, project: "/Users/dev/herdr-ios", title: "herdr-ios"), in: panes), "wN:p1")
        XCTAssertNil(AITopicHerdr.pane(for: topic(.codex, id: UUID().uuidString, project: "/Users/dev/herdr-ios", title: "Ask"), in: panes))
        XCTAssertNil(AITopicHerdr.pane(for: topic(.codex, id: UUID().uuidString, project: "/Users/dev/herdr-ios", title: "Matt"), in: panes))
    }
    func testTrailingSlashAndSubdirectoryProjectsStillMatch() {
        let trailing = topic(.codex, id: UUID().uuidString, project: "/Users/dev/project-b/", title: "codex: project-b")
        XCTAssertEqual(AITopicHerdr.pane(for: trailing, in: agents()), "wS:p1")
        // The Codex process may have moved below its start directory; foreground_cwd covers that.
        let nested = topic(.codex, id: UUID().uuidString, project: "/Users/dev/project-b/sub", title: "codex: project-b")
        XCTAssertEqual(AITopicHerdr.pane(for: nested, in: agents()), "wS:p1")
    }
    func testUnrelatedProjectAndEmptyProjectDoNotMatch() {
        XCTAssertNil(AITopicHerdr.pane(for: topic(.codex, id: UUID().uuidString, project: "/Users/dev/other"), in: agents()))
        XCTAssertNil(AITopicHerdr.pane(for: topic(.claude, id: UUID().uuidString, project: ""), in: agents()))
    }
    func testExecutablePrefersOverrideThenTheStandardInstallPaths() throws {
        let root = try directory(), fake = try script("exit 0", in: root)
        XCTAssertEqual(AITopicHerdr.executable(environment: ["OILFIND_HERDR_BIN": fake], home: root.path), fake)
        XCTAssertNil(AITopicHerdr.executable(environment: ["OILFIND_HERDR_BIN": root.appendingPathComponent("absent").path], home: root.path))
        XCTAssertNil(AITopicHerdr.executable(environment: ["OILFIND_HERDR_BIN": ""], home: root.path))
        let local = root.appendingPathComponent(".local/bin/herdr")
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: local)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: local.path)
        XCTAssertEqual(AITopicHerdr.executable(environment: [:], home: root.path), local.path)
    }
    func testFocusInvokesAgentFocusWithTheMatchedPane() throws {
        let root = try directory(), record = root.appendingPathComponent("focused"), list = root.appendingPathComponent("list.json")
        try Data(payload.utf8).write(to: list)
        let body = "if [ \"$1 $2\" = \"agent list\" ]; then cat '" + list.path + "'; exit 0; fi; "
            + "if [ \"$1 $2\" = \"agent focus\" ]; then echo \"$3\" >> '" + record.path + "'; exit 0; fi; exit 2"
        let fake = try script(body, in: root)
        XCTAssertEqual(AITopicHerdr.list(binary: fake, timeout: 5)?.count, 3)
        let session = topic(.claude, id: "18ca3d84-f5d6-4cc9-8c5b-efd6b0ebacfb", project: "/Users/dev/project-a")
        XCTAssertTrue(AITopicHerdr.focus(session, binary: fake, timeout: 5))
        XCTAssertEqual(try String(contentsOf: record, encoding: .utf8), "wK:p3W\n")
        let unrelated = topic(.codex, id: UUID().uuidString, project: "/Users/dev/elsewhere")
        XCTAssertFalse(AITopicHerdr.focus(unrelated, binary: fake, timeout: 5))
        XCTAssertEqual(try String(contentsOf: record, encoding: .utf8), "wK:p3W\n")
    }
    func testFailuresAndTimeoutsReportNoPane() throws {
        let root = try directory()
        let failing = try script("exit 1", in: root)
        XCTAssertNil(AITopicHerdr.list(binary: failing, timeout: 5))
        XCTAssertFalse(AITopicHerdr.focus(pane: "wK:p3W", binary: failing, timeout: 5))
        let slow = try script("sleep 5", in: root)
        let started = Date()
        XCTAssertNil(AITopicHerdr.run(slow, [], timeout: 0.3))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }
    func testChildEnvironmentDropsHerdrSessionIdentity() throws {
        let root = try directory()
        let fake = try script("echo \"$HERDR_ENV|$HERDR_PANE_ID|$KEPT\"", in: root)
        let output = AITopicHerdr.run(fake, [], timeout: 5, environment: ["HERDR_ENV": "1", "HERDR_PANE_ID": "wK:p3W", "KEPT": "yes"])
        XCTAssertEqual(output.map { String(decoding: $0.data, as: UTF8.self) }, "||yes\n")
    }
    func testCachedPaneIgnoresStaleSnapshots() {
        let topic = topic(.claude, id: "18ca3d84-f5d6-4cc9-8c5b-efd6b0ebacfb", project: "/Users/dev/project-a")
        // A stale cache never answers, so nothing is claimed without fresh evidence.
        let later = Date().addingTimeInterval(3600)
        XCTAssertTrue(AITopicHerdr.cachedAgents(now: later).isEmpty)
        XCTAssertNil(AITopicHerdr.cachedPane(for: topic, now: later))
    }
    func testOpenTargetPreferenceDefaultsToHerdrAndPersists() throws {
        let suite = "oilfind-herdr-target-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let manager = AITopicManager(defaults: defaults, url: try directory().appendingPathComponent("index.sqlite"), detectProviders: { [] })
        XCTAssertEqual(manager.openTarget, .herdr)
        manager.openTarget = .app
        XCTAssertEqual(defaults.string(forKey: AITopicOpenTarget.defaultsKey), "app")
        XCTAssertEqual(AITopicManager(defaults: defaults, url: try directory().appendingPathComponent("index.sqlite"), detectProviders: { [] }).openTarget, .app)
    }
    func testHostBundleIdentifierHonoursOverride() {
        XCTAssertEqual(AITopicHerdr.hostBundleIdentifier(environment: ["OILFIND_HERDR_HOST_BUNDLE": "com.cmuxterm.app"]), "com.cmuxterm.app")
    }
    func testKnownHostsCoverMuxyCmuxAndTerminal() {
        XCTAssertTrue(AITopicHerdr.knownHostBundleIdentifiers.contains("com.muxy.app"))
        XCTAssertTrue(AITopicHerdr.knownHostBundleIdentifiers.contains("com.cmuxterm.app"))
        XCTAssertTrue(AITopicHerdr.knownHostBundleIdentifiers.contains("com.apple.Terminal"))
    }
    func testHostBundleIdentifierResolvesInstalledHost() throws {
        guard AITopicHerdr.executable() != nil else { throw XCTSkip("本机未安装 herdr") }
        guard let host = AITopicHerdr.hostBundleIdentifier() else { throw XCTSkip("无法识别 Herdr 宿主") }
        print("resolved herdr host: \(host)")
        XCTAssertTrue(AITopicHerdr.knownHostBundleIdentifiers.contains(host))
    }
    /// 实机只读联调：本机装有 herdr 时，真实二进制必须能被探测、解析出窗格。
    /// 只调 agent list，不动焦点，也不要求 Muxy 在前台。
    func testRealHerdrBinaryListsPanesWhenInstalled() throws {
        guard let binary = AITopicHerdr.executable() else { throw XCTSkip("本机未安装 herdr") }
        let agents = try XCTUnwrap(AITopicHerdr.list(binary: binary, timeout: 5), "herdr agent list 必须成功")
        XCTAssertFalse(agents.isEmpty, "herdr agent list 应至少返回一个 agent")
        for agent in agents {
            XCTAssertFalse(agent.paneID.isEmpty)
            XCTAssertFalse(agent.name.isEmpty)
        }
        // 缓存预热走同一路径：可见性变化时调用的就是它。
        AITopicHerdr.refresh(force: true)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, AITopicHerdr.cachedAgents().isEmpty { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertFalse(AITopicHerdr.cachedAgents().isEmpty, "预热后缓存必须可用")
    }
}
