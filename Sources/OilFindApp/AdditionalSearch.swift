import AppKit
import OilFindCore

public struct AdditionalSearchAction {
    public enum Kind {
        case open, openApp, openHerdr, copy, copyName
        /// Opening a conversation hands the panel over to the surface that shows it.
        var dismissesPanel: Bool { self == .open || self == .openApp || self == .openHerdr }
    }
    public let kind: Kind
    public let title: String
    public let perform: (@escaping (Bool) -> Void) -> Void
    public init(kind: Kind, title: String, perform: @escaping (@escaping (Bool) -> Void) -> Void) {
        self.kind = kind; self.title = title; self.perform = perform
    }
}

/// A provider-owned result group shown as its own filter next to the file types.
public struct AdditionalSearchCategory: Hashable {
    public let id: String
    public let title: String
    /// Shown in the search field while this category is the active filter.
    public let placeholder: String?
    public init(id: String, title: String, placeholder: String? = nil) {
        self.id = id; self.title = title; self.placeholder = placeholder
    }
}

/// Non-file results share the host list without pretending to be filesystem entries.
public struct AdditionalSearchItem {
    public let id: String
    public let title: String
    public let detail: String
    public let location: String
    public let modified: Date
    public let icon: NSImage
    public let relevance: Int32
    /// Optional provider-owned scope used to remove items when only part of a provider is disabled.
    public let availabilityScope: String?
    /// Short capsule drawn before the title, e.g. the terminal host that already runs the session.
    public let badge: String?
    private let preparedActions: [AdditionalSearchAction]
    private let actionBuilder: (() -> [AdditionalSearchAction])?
    public var actions: [AdditionalSearchAction] { actionBuilder?() ?? preparedActions }
    public init(id: String, title: String, detail: String, location: String, modified: Date, icon: NSImage,
                relevance: Int32 = 0, availabilityScope: String? = nil, badge: String? = nil, actions: [AdditionalSearchAction]) {
        self.id = id; self.title = title; self.detail = detail; self.location = location
        self.modified = modified; self.icon = icon; self.relevance = relevance; self.availabilityScope = availabilityScope
        self.badge = badge; preparedActions = actions; actionBuilder = nil
    }
    init(id: String, title: String, detail: String, location: String, modified: Date, icon: NSImage,
         relevance: Int32 = 0, availabilityScope: String? = nil, badge: String? = nil, actions: @escaping () -> [AdditionalSearchAction]) {
        self.id = id; self.title = title; self.detail = detail; self.location = location
        self.modified = modified; self.icon = icon; self.relevance = relevance; self.availabilityScope = availabilityScope
        self.badge = badge; preparedActions = []; actionBuilder = actions
    }
}

public protocol AdditionalSearchProvider: AnyObject {
    var isEnabled: Bool { get }
    var title: String { get }
    var placeholder: String { get }
    var status: String? { get }
    var onChange: (() -> Void)? { get set }
    /// Extra filter buttons owned by this provider; empty keeps the single AI topics button.
    var categories: [AdditionalSearchCategory] { get }
    /// Returns the currently available subset of a previously displayed result collection.
    func availableItems(from items: [AdditionalSearchItem]) -> [AdditionalSearchItem]
    /// Prepared on the main thread; work runs alongside file search and returns the complete matching collection.
    func prepareSearch(_ query: Query, isCancelled: @escaping () -> Bool) -> () throws -> [AdditionalSearchItem]
    /// A nil category means every category at once; the default ignores categories entirely.
    func prepareSearch(_ query: Query, category: AdditionalSearchCategory?, isCancelled: @escaping () -> Bool) -> () throws -> [AdditionalSearchItem]
    func visibilityChanged(_ visible: Bool)
    func backgroundIndexingChanged(_ busy: Bool)
}
public extension AdditionalSearchProvider {
    var placeholder: String { title }
    var status: String? { nil }
    var categories: [AdditionalSearchCategory] { [AdditionalSearchCategory(id: "", title: title)] }
    func availableItems(from items: [AdditionalSearchItem]) -> [AdditionalSearchItem] { isEnabled ? items : [] }
    func backgroundIndexingChanged(_ busy: Bool) { }
    func prepareSearch(_ query: Query, category: AdditionalSearchCategory?, isCancelled: @escaping () -> Bool) -> () throws -> [AdditionalSearchItem] {
        prepareSearch(query, isCancelled: isCancelled)
    }
}
