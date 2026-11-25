import Foundation

// swiftc -swift-version 5 codes/ios/Shared/Models.swift codes/ios/Shared/TrainingEstimate.swift \
//   codes/ios/Shared/ZoneDwell.swift \
//   codes/ios/Shared/SampleLibrary.swift codes/ios/Shared/Database.swift \
//   codes/ios/Shared/AccountIdentity.swift codes/ios/Shared/Formatting.swift \
//   codes/ios/Shared/RecordFeedList.swift \
//   codes/ios/Shared/RecordListCard.swift \
//   codes/ios/Shared/RecordListThumbnailFile.swift \
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

func listedWorkout(sport: SportKind, start: Date) -> WorkoutRecord {
    WorkoutRecord(
        id: UUID(),
        sport: sport,
        start: start,
        end: start.addingTimeInterval(60),
        distanceMeters: 1000,
        energyKilocalories: 1,
        averageHeartRate: 120,
        averageCadence: 160,
        elevationGainMeters: 0,
        route: [],
        splits: [],
        heartRate: [],
        cadenceSeries: [],
        paceSeries: [],
        stride: [],
        elevation: [],
        groundContact: [],
        power: [],
        origin: .apple,
        healthKitUUID: nil
    )
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

let saturday = date(shanghai, year: 2026, month: 11, day: 21, hour: 15, minute: 52, second: 39)
check(
    RecordListCardText.started(saturday) == "2026-11-21 15:52 星期六",
    "list date drops seconds and writes 星期六"
)
let sunday = date(shanghai, year: 2026, month: 11, day: 15, hour: 7, minute: 41, second: 20)
check(
    RecordListCardText.started(sunday) == "2026-11-15 07:41 星期日",
    "list date writes 星期日"
)
let justAfterMidnight = date(shanghai, year: 2026, month: 11, day: 21, hour: 0, minute: 30, second: 8)
check(
    RecordListCardText.started(justAfterMidnight) == "2026-11-21 00:30 星期六",
    "list date follows the Shanghai calendar, not the machine zone"
)
check(!RecordListCardText.started(saturday).contains(":39"), "seconds are not part of the list date")

check(RecordListCardText.distance(1_500) == "1.5公里", "1.5 km keeps one decimal and 公里")
check(RecordListCardText.distance(25_100) == "25.1公里", "25.1 km")
check(RecordListCardText.distance(123_456.7) == "123.5公里", "large distance rounds to one decimal")
check(RecordListCardText.distance(1) == "—", "a meter or less is missing, not zero")
check(RecordListCardText.distance(0) == "—", "zero distance is missing")
check(RecordListCardText.distance(.nan) == "—", "a non-finite distance is missing")
check(RecordListCardText.clock(29 * 60 + 52) == "00:29:52", "training clock keeps hours")
check(RecordListCardText.clock(4 * 3600 + 29 * 60 + 27) == "04:29:27", "multi-hour training clock")
check(RecordListCardText.clock(100 * 3600) == "100:00:00", "hours past 99 stay in the string")
check(RecordListCardText.clock(-5) == "00:00:00", "a negative duration does not go negative")
check(RecordListCardText.pace(19 * 60 + 21) == "19'21\"", "pace keeps minute and second marks")
check(RecordListCardText.pace(10 * 60 + 43) == "10'43\"", "double-digit pace minutes")
check(RecordListCardText.pace(0) == "—", "missing pace stays —")
check(RecordListCardText.heartRate(146) == "146", "heart rate is the number only")
check(RecordListCardText.heartRate(146.4) == "146", "heart rate rounds")
check(RecordListCardText.heartRate(0) == "—", "missing heart rate stays —")
check(!RecordListCardText.heartRate(146).contains("次"), "the list cell does not add a heart-rate unit")
check(RecordListCardText.load(864) == "864", "load is the integer")
check(RecordListCardText.load(0) == "—", "a zero load is the missing mark")
check(RecordListCardText.load(10_000) == "10000", "a large load stays a full integer")
check(RecordListCardText.energy(312.4) == "312千卡", "energy is whole kilocalories with 千卡")
check(RecordListCardText.energy(0) == "—", "missing energy stays —")
check(
    SportKind.allCases.filter { !$0.listShowsRouteMetrics } == [.functionalStrength, .hiit, .other],
    "strength, mixed training, and other use the energy card"
)
check(RecordListCardText.score == "—", "the list has no per-record score")

check(
    RecordListMetricColumn.allCases.map(\.rawValue) == ["heartRate", "pace", "load", "score"],
    "the lower row is heart rate, pace, load, score"
)
check(
    RecordListMetricColumn.allCases.map(\.unit) == ["次/分", "分/公里", "负荷", "评分"],
    "each secondary metric has a unit caption"
)

check(RecordListCardLayout.standardTextBlock == 110, "standard text block is 110pt")
check(RecordListCardLayout.standardMapBlock == 110, "map block matches the text block")
check(
    RecordListCardLayout.standardHeight
        == RecordListCardLayout.contentInsetVertical * 2 + RecordListCardLayout.standardTextBlock,
    "card height is vertical insets plus the text block"
)
check(
    RecordListCardLayout.informationWidth(cardWidth: 393) == 220,
    "a 393pt phone keeps the 220pt information track"
)
check(
    RecordListCardLayout.informationWidth(cardWidth: 320) == 172,
    "a 320pt phone shrinks the information track instead of covering the map"
)
check(RecordListCardLayout.headerGap == 8, "month and the chips keep an 8pt gap")
check(RecordListCardLayout.filterBarBottom == 10, "header row has 10pt under it")
check(RecordListCardLayout.filterChipGap == 8, "sport chips keep an 8pt gap")
check(RecordListCardLayout.filterChipPaddingH == 12, "chip horizontal padding is 12pt")
check(RecordListCardLayout.filterChipPaddingV == 7, "chip vertical padding is 7pt")
check(RecordListCardLayout.firstCardGap == 10, "first card sits 10pt below the header")
check(RecordListCardLayout.mapSide == 110, "thumbnail side matches the 110pt text block")
check(
    RecordListCardLayout.mapSide == RecordListCardLayout.standardTextBlock,
    "thumbnail side equals the standard text block so bottoms align"
)
check(RecordListCardLayout.titleLine == 22, "the sport chip and date share a 22pt line")
check(RecordListCardLayout.titleToMiddle == 18, "distance sits 18pt under the title row")
check(RecordListCardLayout.upperLine == 32, "the distance line is 32pt")
check(RecordListCardLayout.middleToBottom == 10, "middle to bottom row is 10pt")
check(RecordListCardLayout.lowerBlock == 28, "secondary metrics with units are 28pt")
check(
    abs(RecordListCardLayout.mapTrackInsetFraction - RecordListCardLayout.mapTrackLineWidth / (2 * RecordListCardLayout.mapSide)) < 0.0001,
    "inset is half the stroke over the thumbnail side"
)
check(RecordListCardLayout.mapTrackLineWidth == 5.5, "list track stroke is 5.5pt")
let inset = RecordListCardLayout.mapTrackInsetFraction
let squareTrack = RecordThumbnailFit.normalizedFrame(width: 100, height: 100)
check(abs(squareTrack.x - inset) < 0.001 && abs(squareTrack.y - inset) < 0.001, "a square track meets the stroke inset")
check(abs(squareTrack.x + squareTrack.width / 2 - 0.5) < 0.001, "a square track stays centered")
check(abs(squareTrack.width - (1 - inset * 2)) < 0.001, "a square track fills the inner box")
let wideTrack = RecordThumbnailFit.normalizedFrame(width: 200, height: 40)
check(abs(wideTrack.x - inset) < 0.001, "the long axis meets the side inset")
check(abs(wideTrack.y + wideTrack.height / 2 - 0.5) < 0.001, "the short axis stays centered")
check(wideTrack.height < wideTrack.width, "a wide track is not stretched into a square")
let tallTrack = RecordThumbnailFit.normalizedFrame(width: 10, height: 80)
check(abs(tallTrack.y - inset) < 0.001, "a tall track meets the top and bottom inset")
check(abs(tallTrack.x + tallTrack.width / 2 - 0.5) < 0.001, "a tall track stays horizontally centered")
check(RecordListCardLayout.mapLeading == 10, "map leading inset is 10pt")
check(RecordListCardLayout.mapToContent == 14, "map to metrics gap is 14pt")
check(RecordListCardLayout.contentTrailing == 14, "content trailing inset is 14pt")
check(RecordListCardLayout.contentInsetVertical == 10, "vertical inset is 10pt")

let thumbID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
check(
    RecordListThumbnailFile.relativePath(id: thumbID, basemapToken: "t", side: 110)
        == "record-thumbs/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE-t-110.jpg",
    "list thumbnails live under record-thumbs with id, basemap, and side"
)
check(
    RecordListThumbnailFile.idPrefix(thumbID) == "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE-",
    "delete uses the workout id prefix"
)
check(RecordListThumbnailFile.folder == "record-thumbs", "thumbnail folder name is fixed")

let help = [
    RecordMetricHelp.loadBody,
    RecordMetricHelp.scoreBody,
    RecordMetricHelp.missing
].joined(separator: "\n")
check(!help.contains("AU"), "help does not call the load AU")
check(!help.contains("此稿"), "help does not quote the design draft")
check(!help.contains("任意单位"), "help does not invent an arbitrary unit")
check(RecordMetricHelp.loadBody.contains("Edwards TRIMP"), "load help names the existing calculation")
check(RecordMetricHelp.scoreBody.contains("不展示"), "score help says the list omits the cell")
check(RecordMetricHelp.missing.contains("不是 0"), "missing values are not zero")

check(
    SportKind.allCases.map(\.title) == [
        "户外跑步", "室内跑步", "越野跑", "户外步行", "徒步", "力量训练", "综合训练", "其他"
    ],
    "the app sport list is fixed and ordered"
)
check(SportKind.outdoorRunning.listAccentHex == 0x22C55E, "outdoor running accent")
check(SportKind.functionalStrength.listAccentHex == 0x7C3AED, "strength accent")
check(SportKind.hiit.listAccentHex == 0xEF4444, "mixed training accent")
check(
    SportKind.functionalStrength.listThumbnailAsset == "RecordSportStrength",
    "strength uses the dumbbell list thumbnail"
)
check(
    SportKind.hiit.listThumbnailAsset == "RecordSportHIIT",
    "mixed training uses the checklist list thumbnail"
)
check(SportKind.outdoorRunning.listThumbnailAsset == nil, "running has no glass-plate asset")
check(SportKind.other.listThumbnailAsset == nil, "other falls back to the SF Symbol")
check(SportKind.outdoorWalking.listShowsRouteMetrics, "outdoor walking shows route metrics")
check(SportKind.outdoorWalking.usesOutdoorLocation, "outdoor walking records GPS")
check(SportKind.outdoorWalking.symbol == "figure.walk", "outdoor walking uses the walk symbol")
check(SportKind(rawValue: "running") == .outdoorRunning, "legacy running raw value is outdoor running")
check(SportKind.outdoorRunning.rawValue == "running", "outdoor running keeps the legacy storage key")

let withHeart = listedWorkout(sport: .outdoorRunning, start: saturday)
check(
    RecordListSecondaryMetric.visible(in: withHeart).map(\.column) == [.heartRate, .pace, .load],
    "running shows heart rate, pace, and load when each has a value"
)
check(
    !RecordListSecondaryMetric.visible(in: withHeart).contains { $0.column == .score },
    "missing score is omitted from the secondary row"
)
var noHeart = withHeart
noHeart.averageHeartRate = 0
noHeart.heartRate = []
check(
    !RecordListSecondaryMetric.visible(in: noHeart).contains { $0.column == .heartRate },
    "missing heart rate is omitted from the secondary row"
)
check(
    RecordListSecondaryMetric.visible(in: noHeart).map(\.column).contains(.pace),
    "pace stays when heart rate is missing"
)
var noPace = withHeart
noPace.distanceMeters = 0
check(
    !RecordListSecondaryMetric.visible(in: noPace).contains { $0.column == .pace },
    "missing pace is omitted from the secondary row"
)
let strengthCard = listedWorkout(sport: .functionalStrength, start: saturday)
check(
    !RecordListSecondaryMetric.visible(in: strengthCard).contains { $0.column == .pace },
    "strength cards never show pace"
)

let mixed = [
    listedWorkout(sport: .outdoorRunning, start: date(shanghai, year: 2026, month: 11, day: 21, hour: 8)),
    listedWorkout(sport: .hiking, start: date(shanghai, year: 2026, month: 11, day: 2, hour: 8)),
    listedWorkout(sport: .hiit, start: date(shanghai, year: 2026, month: 11, day: 1, hour: 8)),
    listedWorkout(sport: .other, start: date(shanghai, year: 2026, month: 10, day: 20, hour: 8)),
    listedWorkout(sport: .outdoorRunning, start: date(shanghai, year: 2026, month: 10, day: 3, hour: 8))
]
let runningOnly = RecordListFilter.apply(.outdoorRunning, to: mixed)
check(mixed.count == 5, "filtering does not rewrite the stored array")
check(runningOnly.map(\.sport) == [.outdoorRunning, .outdoorRunning], "running keeps newest-first order")
check(RecordListFilter.apply(nil, to: mixed).count == 5, "全部 keeps every loaded workout")
check(
    RecordListFilter.sports(in: mixed) == [.outdoorRunning, .hiking, .hiit, .other],
    "the menu lists recorded sports in SportKind order"
)
check(
    RecordListFilter.sports(in: [listedWorkout(sport: .outdoorRunning, start: saturday)]) == [.outdoorRunning],
    "a running-only log does not offer hiking"
)
check(
    RecordListFilter.apply(.other, to: mixed).map(\.sport) == [.other],
    "其他 filters Apple activities mapped outside the named list"
)
let filteredSpans = Format.recordMonthSpans(dates: runningOnly.map(\.start))
check(
    filteredSpans.map(\.title) == ["2026年11月", "2026年10月"],
    "the sticky months follow the filtered rows"
)

if failures.isEmpty {
    print("records-list-check ok")
    exit(0)
}
for failure in failures {
    print("FAIL \(failure)")
}
exit(1)
