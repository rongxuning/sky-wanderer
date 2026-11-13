import Foundation

/// Whether a workout started on the current local calendar day.
enum RecordFeedDay {
    /// `calendar` is `Calendar.current` in the record list, so the device time zone decides today.
    /// Checks pass a fixed calendar and `now` instead of reading the machine clock.
    static func isToday(_ start: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        calendar.isDate(start, inSameDayAs: now)
    }
}

/// Newest-first record list. The sticky month bar is separate and is not one of these rows.
enum RecordFeedList {
    enum Row: Equatable {
        case monthHeader(String)
        case card(index: Int)
    }

    /// The first span is the newest month and has no in-list header, so it does not repeat the sticky title.
    /// Each later span gets its 「yyyy年M月」 label immediately before that month's first card.
    static func rows(spans: [RecordMonthSpan]) -> [Row] {
        var rows: [Row] = []
        for (offset, span) in spans.enumerated() {
            if offset > 0 {
                rows.append(.monthHeader(span.title))
            }
            for index in span.range {
                rows.append(.card(index: index))
            }
        }
        return rows
    }

    /// Sticky probes stay on cards. A month header is dropped, so its frame cannot become the top title.
    static func cardAnchors(
        rows: [Row],
        framesByIndex: [Int: RecordMonthAnchor]
    ) -> [RecordMonthAnchor] {
        rows.compactMap { row in
            guard case .card(let index) = row else { return nil }
            return framesByIndex[index]
        }
    }
}

/// One card's frame in the list viewport. `minY` and `maxY` are in that space.
struct RecordMonthAnchor: Equatable {
    var title: String
    var minY: Double
    var maxY: Double
}

enum RecordMonthTracking {
    /// Month of the card closest to the top of the visible list.
    /// A card that still crosses the top edge keeps the title until its bottom leaves that edge.
    static func topTitle(among anchors: [RecordMonthAnchor], listTop: Double = 0) -> String? {
        let visible = anchors.filter { anchor in
            !anchor.title.isEmpty
                && anchor.minY.isFinite
                && anchor.maxY.isFinite
                && anchor.maxY > anchor.minY
                && anchor.maxY > listTop
        }
        return visible.min { $0.minY < $1.minY }?.title
    }
}
