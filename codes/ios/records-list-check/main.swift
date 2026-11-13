import Foundation

// swiftc -swift-version 5 codes/ios/Shared/Models.swift codes/ios/Shared/TrainingEstimate.swift \
//   codes/ios/Shared/ZoneDwell.swift \
//   codes/ios/Shared/SampleLibrary.swift codes/ios/Shared/Database.swift \
//   codes/ios/Shared/AccountIdentity.swift codes/ios/Shared/Formatting.swift \
//   codes/ios/Shared/RecordFeedList.swift \
//   codes/ios/records-list-check/main.swift \
//   -o /tmp/records-list-check && /tmp/records-list-check

/// SampleLibrary's preset route names this. The check does not compile LiveSession.
enum MapOrigin {
    static let fallback = GeoPoint(latitude: 31.24, longitude: 121.49, altitude: 12, timestamp: nil)
}

var failures: [String] = []

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures.append(message)
    }
}

func calendar(timeZone identifier: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.timeZone = TimeZone(identifier: identifier)!
    return calendar
}

func date(_ calendar: Calendar, year: Int, month: Int, day: Int, hour: Int, minute: Int = 0, second: Int = 0) -> Date {
    calendar.date(from: DateComponents(
        year: year, month: month, day: day, hour: hour, minute: minute, second: second
    ))!
}

let losAngeles = calendar(timeZone: "America/Los_Angeles")
let shanghai = calendar(timeZone: "Asia/Shanghai")

// Fixed "now": 2026-11-13 10:00 in Los Angeles. Not Date().
let now = date(losAngeles, year: 2026, month: 11, day: 13, hour: 10)
let todayMorning = date(losAngeles, year: 2026, month: 11, day: 13, hour: 0, minute: 5)
let todayLate = date(losAngeles, year: 2026, month: 11, day: 13, hour: 23, minute: 59, second: 59)
let yesterdayLate = date(losAngeles, year: 2026, month: 11, day: 12, hour: 23, minute: 30)
let anotherDay = date(losAngeles, year: 2026, month: 11, day: 14, hour: 0, minute: 1)

check(
    RecordFeedDay.isToday(todayMorning, now: now, calendar: losAngeles),
    "a workout starting today is today"
)
check(
    RecordFeedDay.isToday(todayLate, now: now, calendar: losAngeles),
    "a workout later the same local day is still today"
)
check(
    RecordFeedDay.isToday(now, now: now, calendar: losAngeles),
    "a workout starting at the fixed now is today"
)
check(
    !RecordFeedDay.isToday(yesterdayLate, now: now, calendar: losAngeles),
    "a workout starting yesterday is not today"
)
check(
    !RecordFeedDay.isToday(anotherDay, now: now, calendar: losAngeles),
    "a workout starting on another day is not today"
)

// 23:30 in Los Angeles is already the next afternoon in Shanghai. The calendar argument decides the day.
let crossed = date(losAngeles, year: 2026, month: 11, day: 12, hour: 23, minute: 30)
let crossedInShanghai = shanghai.dateComponents([.year, .month, .day], from: crossed)
check(
    crossedInShanghai.year == 2026 && crossedInShanghai.month == 11 && crossedInShanghai.day == 13,
    "the fixture falls on November 13 in Shanghai"
)
check(
    !RecordFeedDay.isToday(crossed, now: now, calendar: losAngeles),
    "the same instant is yesterday in the fixed Los Angeles calendar"
)
let shanghaiNow = date(shanghai, year: 2026, month: 11, day: 13, hour: 16)
check(
    RecordFeedDay.isToday(crossed, now: shanghaiNow, calendar: shanghai),
    "the same instant is today in the fixed Shanghai calendar"
)

func shanghaiNoon(year: Int, month: Int, day: Int) -> Date {
    date(shanghai, year: year, month: month, day: day, hour: 12)
}

let novemberNewest = shanghaiNoon(year: 2026, month: 11, day: 12)
let novemberOlder = shanghaiNoon(year: 2026, month: 11, day: 2)
let octoberNewest = shanghaiNoon(year: 2026, month: 10, day: 31)
let octoberOlder = shanghaiNoon(year: 2026, month: 10, day: 1)
let decemberPreviousYear = shanghaiNoon(year: 2025, month: 12, day: 20)

let spans = Format.recordMonthSpans(dates: [
    novemberNewest,
    novemberOlder,
    octoberNewest,
    octoberOlder,
    decemberPreviousYear
])
check(spans.map(\.title) == ["2026年11月", "2026年10月", "2025年12月"], "spans stay newest month first")

let rows = RecordFeedList.rows(spans: spans)
let headers = rows.compactMap { row -> String? in
    if case .monthHeader(let title) = row { return title }
    return nil
}
let cardIndexes = rows.compactMap { row -> Int? in
    if case .card(let index) = row { return index }
    return nil
}

check(headers == ["2026年10月", "2025年12月"], "in-list headers start at the second month")
check(
    !rows.contains(.monthHeader("2026年11月")),
    "the newest month has no in-list header"
)
check(cardIndexes == [0, 1, 2, 3, 4], "every workout stays in newest-first order")
check(
    rows.first == .card(index: 0),
    "the list opens on the newest card, not a repeated month label"
)

// The October header sits immediately before October's first card, and nowhere else.
let octoberHeader = rows.firstIndex(of: .monthHeader("2026年10月"))
let octoberCard = rows.firstIndex(of: .card(index: 2))
check(octoberHeader != nil && octoberCard != nil && octoberHeader! + 1 == octoberCard!, "the October label is directly above its first card")
check(
    rows.firstIndex(of: .monthHeader("2025年12月"))! + 1 == rows.firstIndex(of: .card(index: 4))!,
    "the older year-month label is directly above its first card"
)
check(
    headers.allSatisfy { title in spans.contains(where: { $0.title == title }) },
    "in-list labels use the same year-month string as the spans"
)
check(
    Format.monthTitle(octoberNewest) == "2026年10月",
    "the in-list label matches Format.monthTitle"
)

let oneMonth = Format.recordMonthSpans(dates: [novemberNewest, novemberOlder])
check(
    RecordFeedList.rows(spans: oneMonth).compactMap { row -> String? in
        if case .monthHeader(let title) = row { return title }
        return nil
    }.isEmpty,
    "a single month has no in-list header"
)
check(RecordFeedList.rows(spans: []).isEmpty, "no workouts produce no rows")

// Card frames only. A header frame that still crosses the top would win if it were probed.
let novemberCrossing = RecordMonthAnchor(title: "2026年11月", minY: -28, maxY: 36)
let octoberVisible = RecordMonthAnchor(title: "2026年10月", minY: 180, maxY: 300)
// Sits above every card and still crosses the top edge, so topTitle would pick it if it were probed.
let headerThatWouldSteal = RecordMonthAnchor(title: "2026年10月", minY: -80, maxY: 12)
let frames: [Int: RecordMonthAnchor] = [
    0: novemberCrossing,
    1: RecordMonthAnchor(title: "2026年11月", minY: 48, maxY: 160),
    2: octoberVisible,
    3: RecordMonthAnchor(title: "2026年10月", minY: 312, maxY: 420),
    4: RecordMonthAnchor(title: "2025年12月", minY: 440, maxY: 560)
]
let anchors = RecordFeedList.cardAnchors(rows: rows, framesByIndex: frames)
check(
    anchors == [frames[0]!, frames[1]!, frames[2]!, frames[3]!, frames[4]!],
    "sticky anchors are the card frames, in list order"
)
check(
    !anchors.contains(headerThatWouldSteal),
    "a month header is not a sticky anchor"
)
check(
    RecordMonthTracking.topTitle(among: anchors) == "2026年11月",
    "a card that still crosses the top edge keeps the sticky title"
)
check(
    RecordMonthTracking.topTitle(among: anchors + [headerThatWouldSteal]) == "2026年10月",
    "probing the header would let it steal the sticky title"
)

let novemberLeft = RecordMonthAnchor(title: "2026年11月", minY: -180, maxY: -8)
let octoberNowTop = RecordMonthAnchor(title: "2026年10月", minY: 12, maxY: 140)
check(
    RecordMonthTracking.topTitle(among: [novemberLeft, octoberNowTop]) == "2026年10月",
    "once the newer card's bottom leaves the top edge, the next card's month takes the title"
)
check(
    RecordMonthTracking.topTitle(among: [
        RecordMonthAnchor(title: "2026年11月", minY: -40, maxY: 0),
        octoberNowTop
    ]) == "2026年10月",
    "a card whose bottom is exactly on the top edge has already left"
)
check(
    RecordMonthTracking.topTitle(among: [
        RecordMonthAnchor(title: "", minY: -20, maxY: 40),
        octoberNowTop
    ]) == "2026年10月",
    "an empty title does not become the sticky month"
)

if failures.isEmpty {
    print("records-list-check ok")
    exit(0)
}
for failure in failures {
    print("FAIL \(failure)")
}
exit(1)
