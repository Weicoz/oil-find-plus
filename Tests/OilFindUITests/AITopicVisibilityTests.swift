import AppKit
import XCTest
import OilFindCore
@testable import OilFindApp

final class AITopicVisibilityTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oilfind-visibility-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    private func eventually(_ timeout: Double = 5, _ body: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !body() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return body()
    }
    private func line(_ value: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: value); data.append(10); return data
    }

    func testAutomatedTopicsAreHiddenUnlessIncluded() throws {
        let root = try directory(), url = root.appendingPathComponent("index.sqlite")
        let index = try AITopicIndex(url: url)
        let manual = AITopic(id: "manual", provider: .claude, title: "shared title", modified: 2)
        let automated = AITopic(id: "auto", provider: .claude, title: "shared title", modified: 3, automated: true)
        try index.transaction {
            try index.upsert(manual); try index.upsert(automated)
            try index.message(manual.key, key: "body", body: "sharedbody")
            try index.message(automated.key, key: "body", body: "sharedbody")
        }
        let reader = try AITopicIndex(url: url, readOnly: true)
        XCTAssertEqual(try reader.search("sharedbody").topics.map(\.key), [manual.key])
        XCTAssertEqual(try reader.search("sharedbody", includeAutomated: true).topics.count, 2)
        XCTAssertEqual(try reader.count(), 1)
        XCTAssertEqual(try reader.count(includeAutomated: true), 2)
        XCTAssertEqual(try reader.search("sharedbody", includeAutomated: true).topics.first { $0.key == automated.key }?.automated, true)
        XCTAssertEqual(try reader.search("sharedbody").topics.first?.automated, false)
    }

    func testArchivedAutomatedTopicsStayHidden() throws {
        let root = try directory(), url = root.appendingPathComponent("index.sqlite")
        let index = try AITopicIndex(url: url)
        try index.upsert(AITopic(id: "archived-auto", provider: .codex, title: "archived title", archived: true, automated: true))
        XCTAssertTrue(try index.search("archived title", includeAutomated: true).topics.isEmpty)
        XCTAssertEqual(try index.count(includeAutomated: true), 0)
    }

    func testClaudeHeadlessEntrypointIsMarkedAutomated() throws {
        let root = try directory(), home = root.appendingPathComponent("home")
        let project = home.appendingPathComponent(".claude/projects/demo")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        func write(entrypoint: String, body: String) throws {
            let file = project.appendingPathComponent(UUID().uuidString.lowercased() + ".jsonl")
            try line(["type": "user", "cwd": "/demo", "entrypoint": entrypoint, "message": ["content": body]]).write(to: file)
        }
        try write(entrypoint: "sdk-cli", body: "headlessclaudebody")
        try write(entrypoint: "cli", body: "interactiveclaudebody")
        let index = try AITopicIndex(url: root.appendingPathComponent("index.sqlite"))
        try AITopicIndexer(index: index, locations: .init(home: home)).refresh(providers: [.claude])
        XCTAssertEqual(try index.search("headlessclaudebody", includeAutomated: true).topics.first?.automated, true)
        XCTAssertEqual(try index.search("interactiveclaudebody", includeAutomated: true).topics.first?.automated, false)
        XCTAssertTrue(try index.search("headlessclaudebody").topics.isEmpty)
        XCTAssertEqual(try index.search("interactiveclaudebody").topics.count, 1)
    }

    func testCodexHeadlessRolloutsAreMarkedAutomated() throws {
        let root = try directory(), home = root.appendingPathComponent("home")
        let sessions = home.appendingPathComponent(".codex/sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        func write(_ name: String, payload: [String: Any], body: String) throws {
            let header = try line(["type": "session_meta", "payload": payload])
            let message = try line(["type": "response_item",
                "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": body]]]])
            try (header + message).write(to: sessions.appendingPathComponent("rollout-" + name + ".jsonl"))
        }
        try write("exec", payload: ["id": UUID().uuidString.lowercased(), "cwd": "/demo", "originator": "codex_exec"], body: "headlesscodexbody")
        try write("plain", payload: ["id": UUID().uuidString.lowercased(), "cwd": "/demo", "originator": "codex-tui"], body: "interactivecodexbody")
        try write("sub", payload: ["id": UUID().uuidString.lowercased(), "cwd": "/demo", "source": ["subagent": "review"]], body: "subagentcodexbody")
        let index = try AITopicIndex(url: root.appendingPathComponent("index.sqlite"))
        try AITopicIndexer(index: index, locations: .init(home: home, codex: home.appendingPathComponent(".codex"))).refresh(providers: [.codex])
        XCTAssertEqual(try index.search("headlesscodexbody", includeAutomated: true).topics.first?.automated, true)
        XCTAssertEqual(try index.search("interactivecodexbody", includeAutomated: true).topics.first?.automated, false)
        XCTAssertEqual(try index.search("subagentcodexbody", includeAutomated: true).topics.first?.automated, true)
        XCTAssertTrue(try index.search("headlesscodexbody").topics.isEmpty)
        XCTAssertTrue(try index.search("subagentcodexbody").topics.isEmpty)
        XCTAssertEqual(try index.search("interactivecodexbody").topics.count, 1)
    }

    func testFilterBarSelectsAnyAdditionalCategory() throws {
        let bar = FilterBar(frame: NSRect(x: 0, y: 0, width: 640, height: 40))
        bar.additionalTitles = ["AI Topics", "Herdr"]
        XCTAssertFalse(bar.additionalSelected)
        bar.select(FilterBar.names.count + 1)
        XCTAssertTrue(bar.additionalSelected)
        XCTAssertEqual(bar.additionalIndex, 1)
        XCTAssertEqual(bar.additionalTitle, "AI Topics")
        bar.select(FilterBar.names.count)
        XCTAssertEqual(bar.additionalIndex, 0)
        XCTAssertTrue(bar.additionalSelected)
        // Shrinking keeps a still-valid selection, then drops it once the category disappears.
        bar.additionalTitles = ["AI Topics"]
        XCTAssertEqual(bar.additionalIndex, 0)
        bar.additionalTitles = []
        XCTAssertNil(bar.additionalIndex)
        XCTAssertFalse(bar.additionalSelected)
        XCTAssertNil(bar.additionalTitle)
    }

    func testHerdrCategoryListsLivePanesAndMarksMatchingTopics() throws {
        let root = try directory(), url = root.appendingPathComponent("index.sqlite")
        let session = UUID().uuidString.lowercased()
        let index = try AITopicIndex(url: url)
        let topic = AITopic(id: session, provider: .claude, title: "herdr provider topic", project: "/demo/herdr", modified: Date().timeIntervalSince1970)
        try index.upsert(topic); try index.message(topic.key, key: "body", body: "herdrproviderbody")
        let suite = "oilfind-visibility-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = AITopicManager(defaults: defaults, url: url, detectProviders: { [.claude] })

        let script = root.appendingPathComponent("fake-herdr")
        let payload: [String: Any] = ["result": ["agents": [[
            "agent": "claude", "agent_status": "running", "cwd": "/demo/herdr", "pane_id": "wTEST:p1",
            "terminal_title": "herdr provider topic", "terminal_title_stripped": "herdr provider topic",
            "focused": true, "agent_session": ["agent": "claude", "kind": "id", "source": "herdr:claude", "value": session],
        ]]]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        try ("#!/bin/sh\nprintf '%s' '" + json.replacingOccurrences(of: "'", with: "'\\''") + "'\n").write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        setenv("OILFIND_HERDR_BIN", script.path, 1)
        defer { unsetenv("OILFIND_HERDR_BIN") }
        AITopicHerdr.refresh(force: true)
        XCTAssertTrue(eventually { AITopicHerdr.cachedAgents().contains { $0.paneID == "wTEST:p1" } })

        let provider = AITopicSearchProvider(manager: manager)
        XCTAssertEqual(provider.categories.map(\.id), ["topics", "herdr"])
        XCTAssertEqual(provider.categories.map(\.title), [provider.title, "Herdr"])

        let topicsCategory = try XCTUnwrap(provider.categories.first)
        let herdrCategory = try XCTUnwrap(provider.categories.last)
        let marked = try provider.prepareSearch(.parse("herdrproviderbody"), category: topicsCategory, isCancelled: { false })()
        XCTAssertEqual(marked.count, 1)
        XCTAssertEqual(marked.first?.badge, "Herdr")
        XCTAssertEqual(marked.first?.location, "Claude Code · herdr")

        let panes = try provider.prepareSearch(.parse("provider"), category: herdrCategory, isCancelled: { false })()
        XCTAssertEqual(panes.count, 1)
        XCTAssertEqual(panes.first?.id, "herdr:wTEST:p1")
        XCTAssertNil(panes.first?.badge)
        XCTAssertEqual(panes.first?.location, "wTEST:p1")
        XCTAssertTrue(try provider.prepareSearch(.parse("unrelatedword"), category: herdrCategory, isCancelled: { false })().isEmpty)

        // The mixed list carries both the topic row and the live pane row.
        let mixed = try provider.prepareSearch(.parse("herdr"), category: nil, isCancelled: { false })()
        XCTAssertEqual(Set(mixed.map(\.id)), Set([topic.key, "herdr:wTEST:p1"]))
    }
}
