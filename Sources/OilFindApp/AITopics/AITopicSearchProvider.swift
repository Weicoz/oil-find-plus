import AppKit
import OilFindCore

final class AITopicSearchProvider: AdditionalSearchProvider {
    private static let topicsCategory = "topics"
    private static let herdrCategory = "herdr"
    private let manager: AITopicManager
    private let icons = AITopicIcons()
    private var chinese: Bool { L10n.chinese }
    var onChange: (() -> Void)?
    var isEnabled: Bool { manager.isEnabled }
    var placeholder: String { L10n.text("topicsPlaceholder", chinese: chinese) }
    var title: String { L10n.text("topicsTitle", chinese: chinese) }
    var status: String? {
        manager.failed ? L10n.text("topicsSyncFailed", chinese: chinese) : manager.indexing ? L10n.text("topicsBuildingShort", chinese: chinese) : nil
    }
    /// Herdr gets its own filter, but only where the CLI exists.
    var categories: [AdditionalSearchCategory] {
        var result = [AdditionalSearchCategory(id: Self.topicsCategory, title: title)]
        if AITopicHerdr.executable() != nil {
            result.append(AdditionalSearchCategory(id: Self.herdrCategory, title: "Herdr", placeholder: L10n.text("topicsHerdrPlaceholder", chinese: chinese)))
        }
        return result
    }
    init(manager: AITopicManager) {
        self.manager = manager
        manager.onChange = { [weak self] in self?.onChange?() }
        manager.onAvailabilityChange = { [weak self] in self?.onChange?() }
    }
    func visibilityChanged(_ visible: Bool) {
        manager.visibilityChanged(visible)
        // Warm the pane cache while the panel is open, so menus know about live Herdr sessions.
        if visible { AITopicHerdr.refresh() }
    }
    func backgroundIndexingChanged(_ busy: Bool) { manager.backgroundIndexingChanged(busy) }
    func availableItems(from items: [AdditionalSearchItem]) -> [AdditionalSearchItem] {
        guard isEnabled else { return [] }
        let scopes = Set(manager.enabledProviders.map(\.rawValue))
        // Pane rows carry no provider scope; they live and die with the provider itself.
        return items.filter { item in item.availabilityScope.map(scopes.contains) ?? true }
    }
    func prepareSearch(_ query: Query, isCancelled: @escaping () -> Bool) -> () throws -> [AdditionalSearchItem] {
        // Legacy entry point: topics only. The mixed list is requested explicitly with a nil category.
        prepareSearch(query, category: categories.first, isCancelled: isCancelled)
    }
    func prepareSearch(_ query: Query, category: AdditionalSearchCategory?, isCancelled: @escaping () -> Bool) -> () throws -> [AdditionalSearchItem] {
        let images = Dictionary(uniqueKeysWithValues: AITopicProvider.allCases.map { ($0, icons.image($0)) })
        let terminal = Theme.symbol("terminal", size: 19, weight: .regular)
        let chinese = chinese
        let terms = AITopicIndex.fold(query.raw).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let selected = category?.id
        return { [manager] in
            // A nil category means the file filters are active: Herdr sessions join the mixed list.
            // The Herdr filter asks the CLI directly; other lists reuse the last snapshot so typing never blocks.
            let agents = selected == Self.herdrCategory ? AITopicHerdr.liveAgents() : AITopicHerdr.displayAgents()
            var items: [AdditionalSearchItem] = []
            if selected == nil || selected == Self.topicsCategory {
                let found = try manager.readSearch(query.raw, isCancelled: isCancelled)
                if isCancelled() { return [] }
                items += Self.topicItems(found.topics, manager: manager, images: images, chinese: chinese, terms: terms,
                                         agents: agents, isCancelled: isCancelled)
            }
            if (selected == nil || selected == Self.herdrCategory) && !isCancelled() {
                items += Self.paneItems(agents, chinese: chinese, terms: terms, images: images, terminal: terminal, isCancelled: isCancelled)
            }
            return items
        }
    }
    private static func topicItems(_ topics: [AITopic], manager: AITopicManager, images: [AITopicProvider: NSImage], chinese: Bool,
                                   terms: [String], agents: [AITopicHerdr.Agent], isCancelled: () -> Bool) -> [AdditionalSearchItem] {
        topics.map { topic in
            let topicKey = topic.key
            // A live pane is what makes the Herdr capsule honest: the session really runs there.
            let badge = AITopicHerdr.pane(for: topic, in: agents) == nil ? nil : "Herdr"
            let actions = { () -> [AdditionalSearchAction] in
                let preferred = manager.openTarget
                var definitions: [(AdditionalSearchAction.Kind, String)] = [(.open, "topicsOpen")]
                // Offer the other surface only when the two would actually differ.
                if AITopicHerdr.cachedPane(for: topic) != nil {
                    definitions.append(preferred == .app ? (.openHerdr, "topicsOpenHerdr") : (.openApp, "topicsOpenApp"))
                }
                definitions.append(contentsOf: [(.copy, "topicsCopyResume"), (.copyName, "topicsCopyTitle")])
                return definitions.map { (kind: AdditionalSearchAction.Kind, label: String) in
                    AdditionalSearchAction(kind: kind, title: L10n.text(label, chinese: chinese)) { completion in
                        manager.resolve(topicKey) { current in
                            guard let current else { completion(false); return }
                            switch kind {
                            case .open: Self.open(current, target: preferred, fallback: true, completion: completion)
                            case .openApp: completion(AITopicActions.open(current))
                            case .openHerdr: Self.open(current, target: .herdr, fallback: false, completion: completion)
                            case .copy:
                                AITopicActions.copyResume(current)
                                completion(true)
                            case .copyName:
                                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(current.title, forType: .string); completion(true)
                            }
                        }
                    }
                }
            }
            let project = topic.project.isEmpty ? "" : " · " + URL(fileURLWithPath: topic.project).lastPathComponent
            return AdditionalSearchItem(id: topicKey, title: topic.title.isEmpty ? L10n.text("topicsUntitled", chinese: chinese) : topic.title,
                detail: topic.excerpt, location: topic.provider.name + project, modified: Date(timeIntervalSince1970: topic.modified),
                icon: images[topic.provider]!, relevance: relevance(topic, terms: terms), availabilityScope: topic.provider.rawValue,
                badge: badge, actions: actions)
        }
    }
    private static func paneItems(_ agents: [AITopicHerdr.Agent], chinese: Bool, terms: [String],
                                  images: [AITopicProvider: NSImage], terminal: NSImage, isCancelled: () -> Bool) -> [AdditionalSearchItem] {
        agents.compactMap { agent -> AdditionalSearchItem? in
            if isCancelled() { return nil }
            let haystack = AITopicIndex.fold([agent.title, agent.name, agent.cwd, agent.paneID].joined(separator: " "))
            guard terms.allSatisfy({ haystack.contains($0) }) else { return nil }
            let pane = agent.paneID
            let project = agent.cwd.isEmpty ? "" : URL(fileURLWithPath: agent.cwd).lastPathComponent
            let provider = AITopicProvider.allCases.first { agent.name.lowercased().contains($0.rawValue) }
            let actions = { () -> [AdditionalSearchAction] in
                [AdditionalSearchAction(kind: .openHerdr, title: L10n.text("topicsOpenHerdr", chinese: chinese)) { completion in
                    DispatchQueue.global(qos: .userInitiated).async {
                        let focused = AITopicHerdr.focus(pane: pane)
                        DispatchQueue.main.async {
                            if focused { AITopicHerdr.raiseHost(); completion(true) } else { completion(false) }
                        }
                    }
                 },
                 AdditionalSearchAction(kind: .copyName, title: L10n.text("topicsCopyTitle", chinese: chinese)) { completion in
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(agent.title, forType: .string); completion(true)
                 }]
            }
            return AdditionalSearchItem(id: "herdr:" + pane, title: agent.title.isEmpty ? agent.name : agent.title,
                detail: [project, agent.name].filter { !$0.isEmpty }.joined(separator: " · "), location: pane,
                modified: Date(), icon: provider.map { images[$0]! } ?? terminal, relevance: relevance(agent, terms: terms), actions: actions)
        }
    }
    /// Opens the topic in its Herdr pane. The default target falls back to the app; an explicit
    /// request does not, so a stale pane never silently opens a different surface.
    private static func open(_ topic: AITopic, target: AITopicOpenTarget, fallback: Bool, completion: @escaping (Bool) -> Void) {
        guard target == .herdr else { completion(AITopicActions.open(topic)); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let focused = AITopicHerdr.focus(topic)
            DispatchQueue.main.async {
                if focused { AITopicHerdr.raiseHost(); completion(true) }
                else { completion(fallback ? AITopicActions.open(topic) : false) }
            }
        }
    }
    private static func relevance(_ agent: AITopicHerdr.Agent, terms: [String]) -> Int32 {
        guard !terms.isEmpty else { return agent.focused ? 40 : 0 }
        let title = AITopicIndex.fold(agent.title)
        let scores = terms.map { term -> Int in
            if title == term { return 1000 }
            if title.hasPrefix(term) { return 800 }
            if title.range(of: term) != nil { return 600 }
            return 250
        }
        let average = scores.reduce(0, +) / max(1, scores.count)
        return Int32(average + (agent.focused ? 40 : 0))
    }
    private static func relevance(_ topic: AITopic, terms: [String]) -> Int32 {
        let title = AITopicIndex.fold(topic.title)
        guard !terms.isEmpty else { return 0 }
        let scores = terms.map { term -> Int in
            if title == term { return 1000 }
            if title.hasPrefix(term) { return 800 }
            if title.range(of: term) != nil { return 600 }
            return 250
        }
        let length = max(0, title.utf8.count - terms.reduce(0) { $0 + $1.utf8.count })
        let age = Date().timeIntervalSince1970 - topic.modified
        let recent = age <= 86400 ? 60 : age <= 604800 ? 45 : age <= 2592000 ? 30 : age <= 31536000 ? 10 : 0
        let average: Int = scores.reduce(0, +) / scores.count
        let lengthPenalty: Int = 2 * min(length, 64)
        let rank: Int = average - lengthPenalty + 60 + recent
        return Int32(rank)
    }
}
