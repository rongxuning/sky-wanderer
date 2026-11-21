import Foundation

// swiftc -swift-version 5 \
//   codes/ios/Shared/Models.swift \
//   codes/ios/Shared/RouteStats.swift \
//   codes/ios/Shared/PhoneWatchLiveSync.swift \
//   codes/ios/phone-watch-live-check/main.swift \
//   -o /tmp/phone-watch-live-check && /tmp/phone-watch-live-check

var failures: [String] = []

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures.append(message)
    }
}

func near(_ actual: Double, _ expected: Double, _ tolerance: Double, _ message: String) {
    check(abs(actual - expected) <= tolerance, "\(message): \(actual) !~ \(expected)")
}

let route = (0..<200).map { index in
    GeoPoint(
        latitude: 31.24 + Double(index) * 0.0001,
        longitude: 121.49,
        altitude: 12 + Double(index) * 0.05,
        timestamp: nil
    )
}
let marks = [
    KilometerMarker(kilometer: 1, latitude: 31.25, longitude: 121.49, altitude: 20, distanceMeters: 1000),
    KilometerMarker(kilometer: 2, latitude: 31.26, longitude: 121.49, altitude: 28, distanceMeters: 2000)
]
let snap = PhoneWatchLiveSnapshot.from(
    sport: .running,
    elapsed: 625,
    distanceMeters: 2_150,
    paceSecPerKm: 290,
    heartRate: 158,
    cadence: 172,
    altitudeMeters: 34,
    paused: false,
    userFix: route.last,
    route: route,
    kilometers: marks,
    routeLimit: 80
)

check(snap.active, "active snapshot")
check(snap.sport == .running, "sport round-trips")
check(snap.route.count == 80, "route is compacted to the limit, got \(snap.route.count)")
check(snap.kilometers.count == 2, "kilometer marks travel with the snapshot")
near(snap.route.first?.lat ?? -1, route.first?.latitude ?? -2, 0.00001, "first route point kept")
near(snap.route.last?.lat ?? -1, route.last?.latitude ?? -2, 0.00001, "last route point kept")
near(snap.altitudeMeters, 34, 0.01, "altitude")

let payload = try! snap.dictionary()
let decoded = PhoneWatchLiveSnapshot.decode(from: payload)
check(decoded != nil, "dictionary decode")
check(decoded?.elapsed == 625, "elapsed survives the wire")
check(decoded?.kilometerMarks.count == 2, "kilometer markers decode")
check(decoded?.routePoints.count == 80, "route points decode")
near(decoded?.userFix?.latitude ?? -1, route.last?.latitude ?? -2, 0.00001, "user fix")

let idle = PhoneWatchLiveSnapshot.idle()
check(!idle.active, "idle clears the watch UI")
check(idle.route.isEmpty, "idle has no route")

let short = PhoneWatchLiveSnapshot.compactRoute(Array(route.prefix(12)), limit: 80)
check(short.count == 12, "short routes are not padded")

if failures.isEmpty {
    print("phone-watch-live-check: ok")
    exit(0)
}

print("phone-watch-live-check failed:")
for failure in failures {
    print("- \(failure)")
}
exit(1)
