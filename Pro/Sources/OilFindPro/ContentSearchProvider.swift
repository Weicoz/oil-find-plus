import Foundation
import OilFindCore
import OilFindApp

public final class ContentSearchProvider: SupplementarySearchProvider {
    public var isEnabled: Bool {
        get { manager.isOcrEnabled }
        set { manager.setOcrEnabled(newValue) }
    }
    private var sources: [SearchSource] = []
    private let manager = ContentManager.shared

    public init() {}

    public func prepareSearch(_ query: Query, options: SearchOptions, sources: [SearchSource], isCancelled: @escaping () -> Bool) -> () -> [SupplementaryHit] {
        let rawQuery = query.raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEnabled, rawQuery.count >= 2 else {
            return { [] }
        }
        let capturedSources = sources

        return { [weak self] in
            guard let self = self, !isCancelled() else { return [] }
            let hits = self.manager.search(query: rawQuery, limit: 50, isCancelled: isCancelled)
            guard !isCancelled() else { return [] }

            var results: [SupplementaryHit] = []
            for hit in hits {
                if isCancelled() { break }
                for source in capturedSources where source.isOnline {
                    let (entryID, version) = source.store.read {
                        (source.store.resolve(path: hit.path), source.store.version)
                    }
                    if let entryID = entryID {
                        results.append(SupplementaryHit(
                            sourceID: source.id,
                            entryID: entryID,
                            detail: hit.snippet,
                            highlights: hit.highlightRanges,
                            thumbnail: true,
                            sourceVersion: version
                        ))
                        break
                    }
                }
            }
            return results
        }
    }

    public func sourcesDidChange(_ sources: [SearchSource]) {
        self.sources = sources
        if isEnabled {
            manager.startIndexing(sources: sources)
        }
    }

    public func userActivity(visible: Bool, typing: Bool) {
        if typing {
            manager.recordTyping()
        }
    }

    public func backgroundIndexingChanged(_ busy: Bool) {
        manager.setBackgroundBusy(busy)
    }
}
