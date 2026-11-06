import Foundation

// swiftc -swift-version 5 codes/ios/Shared/Models.swift codes/ios/Shared/TrainingEstimate.swift \
//   codes/ios/Shared/SampleLibrary.swift codes/ios/Shared/Formatting.swift \
//   codes/ios/Shared/WorkoutContext.swift codes/ios/workout-context-check/main.swift \
//   -o /tmp/workout-context-check && /tmp/workout-context-check

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

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 8 * 3600)!
var parts = DateComponents()
parts.calendar = calendar
parts.timeZone = calendar.timeZone
parts.year = 2026
parts.month = 11
parts.day = 5
parts.hour = 15
parts.minute = 4
parts.second = 0
let start = calendar.date(from: parts)!
parts.minute = 56
let end = calendar.date(from: parts)!

check(Format.dateSpan(from: start, to: end) == "2026年11月5日 15:04–15:56", "detail date includes the year")
check(Format.dayTime(start) == "11月5日 15:04", "home day format stays without a year")
check(Format.time(end) == "15:56", "clock stays HH:mm")
check(WorkoutContext.hourKey(start) == "2026-11-05T15", "hour key is the Shanghai hour")
check(WorkoutContext.dayString(start) == "2026-11-05", "day is the Shanghai date")

check(Format.celsius(nil) == "—", "missing temperature")
check(Format.celsius(0) == "0.0°C", "zero celsius is real")
check(Format.celsius(-2.26) == "-2.3°C", "temperature rounds to one decimal")
check(Format.humidity(nil) == "—", "missing humidity")
check(Format.humidity(0) == "0%", "zero humidity is real")
check(Format.humidity(71) == "71%", "humidity percent")
check(Format.humidity(101) == "—", "humidity above 100 is missing")
check(Format.airQuality(index: nil, grade: nil) == "—", "missing air")
check(Format.airQuality(index: 84, grade: "良") == "84 良", "stored air grade")
check(Format.airQuality(index: 42, grade: nil) == "42 优", "grade is derived when absent")
check(Format.airQuality(index: 0, grade: "优") == "0 优", "aqi zero is real")

let grades = [
    (0, "优"), (50, "优"), (51, "良"), (100, "良"),
    (101, "轻度"), (150, "轻度"), (151, "中度"), (200, "中度"),
    (201, "重度"), (300, "重度"), (301, "严重")
]
for (index, grade) in grades {
    check(Format.airQualityGrade(index) == grade, "grade \(index) is \(grade)")
}

check(
    Format.startPoint(name: "上海长风公园", latitude: 31.2291234, longitude: 121.3969876) == "上海长风公园 · 31.229123, 121.396988",
    "place line keeps six decimals"
)
check(Format.startPoint(name: nil, latitude: 31.2, longitude: 121.4) == "31.200000, 121.400000", "coordinates without a name")
check(Format.startPoint(name: "  ", latitude: 31.2, longitude: 121.4) == "31.200000, 121.400000", "blank name is omitted")
check(Format.startPoint(name: "公园", latitude: nil, longitude: nil) == "—", "no coordinate is a dash")
check(Format.startPoint(name: nil, latitude: 120, longitude: 10) == "—", "latitude out of range is a dash")

check(
    WorkoutContext.placeName(
        interest: "上海长风公园",
        name: "长宁路",
        locality: "上海",
        subLocality: nil,
        thoroughfare: nil,
        subThoroughfare: nil
    ) == "上海长风公园",
    "interest wins"
)
check(
    WorkoutContext.placeName(
        interest: "  ",
        name: "长宁路",
        locality: nil,
        subLocality: nil,
        thoroughfare: nil,
        subThoroughfare: nil
    ) == "长宁路",
    "blank interest falls through to the name"
)
check(
    WorkoutContext.placeName(
        interest: nil,
        name: nil,
        locality: "上海市",
        subLocality: "长宁区",
        thoroughfare: "天山路",
        subThoroughfare: "1号"
    ) == "上海市长宁区天山路1号",
    "address is joined when no name exists"
)
check(
    WorkoutContext.placeName(
        interest: nil,
        name: nil,
        locality: nil,
        subLocality: nil,
        thoroughfare: nil,
        subThoroughfare: nil
    ) == nil,
    "empty placemark has no name"
)

let weather = """
{"hourly":{"time":["2026-11-05T14:00","2026-11-05T15:00"],"temperature_2m":[18.2,null],"relative_humidity_2m":[60,71]}}
""".data(using: .utf8)!
let air = """
{"hourly":{"time":["2026-11-05T15:00"],"us_aqi":[84.2]}}
""".data(using: .utf8)!
let read = WorkoutContext.interpret(weatherJSON: weather, airJSON: air, start: start)
check(read.weatherReady, "null temperature still marks the hour fetched")
check(read.temperatureCelsius == nil, "null temperature is not invented")
check(read.relativeHumidityPercent == 71, "humidity is the start hour")
check(read.airReady, "air hour is fetched")
check(read.airQualityIndex == 84, "aqi rounds to an integer")
check(read.airQualityGrade == "良", "aqi grade is stored")

let otherHour = """
{"hourly":{"time":["2026-11-05T14:00"],"temperature_2m":[18],"relative_humidity_2m":[70]}}
""".data(using: .utf8)!
let gap = WorkoutContext.interpret(weatherJSON: otherHour, airJSON: nil, start: start)
check(gap.weatherReady == false, "a neighboring hour is not used")
check(gap.temperatureCelsius == nil, "missing hour stores no temperature")

let bad = #"{"error":true,"reason":"out of range"}"#.data(using: .utf8)!
let missed = WorkoutContext.interpret(weatherJSON: bad, airJSON: nil, start: start)
check(missed.weatherReady == false, "an error payload is not cached as weather")

let weatherOnly = WorkoutConditions(temperatureCelsius: 18.7, relativeHumidityPercent: 71, weatherReady: true)
let airOnly = WorkoutConditions(airQualityIndex: 84, airQualityGrade: "良", airReady: true)
let merged = WorkoutConditions.merging(weatherOnly, with: airOnly)
check(merged.temperatureCelsius == 18.7 && merged.relativeHumidityPercent == 71, "air fill keeps weather")
check(merged.airQualityIndex == 84 && merged.airQualityGrade == "良", "air fill writes aqi")
check(merged.weatherReady && merged.airReady, "both sources are ready")
let cleared = WorkoutConditions.merging(weatherOnly, with: WorkoutConditions(weatherReady: true))
check(cleared.temperatureCelsius == nil && cleared.weatherReady, "a fetched null replaces a stale temperature")
check(cleared.airReady == false, "a weather fill does not mark air ready")

let now = Date(timeIntervalSince1970: 1_800_000_000)
let recent = now.addingTimeInterval(-10 * 86_400)
let old = now.addingTimeInterval(-200 * 86_400)
check(WorkoutContext.weatherBases(start: recent, now: now).count == 2, "recent workouts can fall back to the forecast API")
check(
    WorkoutContext.weatherBases(start: recent, now: now).first == "https://archive-api.open-meteo.com/v1/archive",
    "archive is tried first"
)
check(
    WorkoutContext.weatherBases(start: old, now: now) == ["https://archive-api.open-meteo.com/v1/archive"],
    "old workouts use the archive only"
)

let url = WorkoutContext.endpoint(
    "https://archive-api.open-meteo.com/v1/archive",
    latitude: 31.229,
    longitude: 121.396,
    day: "2026-11-05",
    hourly: "temperature_2m,relative_humidity_2m",
    extra: [URLQueryItem(name: "temperature_unit", value: "celsius")]
)
let text = url?.absoluteString ?? ""
check(text.contains("latitude=31.229000"), "url keeps six latitude decimals")
check(text.contains("longitude=121.396000"), "url keeps six longitude decimals")
check(text.contains("start_date=2026-11-05"), "url uses the workout day")
check(text.contains("timezone=Asia"), "url asks for Shanghai time")

if failures.isEmpty {
    print("workout-context-check ok")
} else {
    for failure in failures {
        print("FAIL \(failure)")
    }
    exit(1)
}
