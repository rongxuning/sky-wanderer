import Foundation

/// Filters the routes library by name. Empty query keeps the full list.
enum RouteListSearch {
    static func apply(_ query: String, to routes: [SavedRoute]) -> [SavedRoute] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return routes }
        return routes.filter { matches($0.name, query: trimmed) }
    }

    /// Case- and diacritic-insensitive. Prefer substring; otherwise require the
    /// query characters to appear in order (simple fuzzy).
    static func matches(_ name: String, query: String) -> Bool {
        let haystack = normalize(name)
        let needle = normalize(query)
        guard !needle.isEmpty else { return true }
        if haystack.localizedStandardContains(needle) { return true }
        return subsequence(haystack, contains: needle)
    }

    private static func normalize(_ text: String) -> String {
        text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func subsequence(_ haystack: String, contains needle: String) -> Bool {
        var index = haystack.startIndex
        for character in needle {
            guard let found = haystack[index...].firstIndex(of: character) else {
                return false
            }
            index = haystack.index(after: found)
        }
        return true
    }
}
