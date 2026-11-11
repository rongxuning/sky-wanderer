import Foundation

// swiftc codes/ios/Shared/Models.swift codes/ios/Shared/SampleLibrary.swift \
//   codes/ios/Shared/AccountIdentity.swift codes/ios/Shared/Database.swift \
//   codes/ios/Shared/TrainingEstimate.swift codes/ios/Shared/GPXFile.swift \
//   codes/ios/Shared/RouteStats.swift codes/ios/Shared/RouteGPXStore.swift \
//   codes/ios/route-checkpoint-check/main.swift \
//   -o /tmp/route-checkpoint-check && /tmp/route-checkpoint-check

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

func near(_ actual: Double, _ expected: Double, _ tolerance: Double, _ message: String) {
    check(abs(actual - expected) <= tolerance, "\(message): \(actual) !~ \(expected)")
}

func point(_ latitude: Double, _ longitude: Double, _ altitude: Double) -> GeoPoint {
    GeoPoint(latitude: latitude, longitude: longitude, altitude: altitude, timestamp: nil)
}

func parse(_ xml: String) -> [GPXTrack] {
    GPXFile.parse(Data(xml.utf8))
}

let oldJSON = """
{"id":"old","name":"旧路线","points":[{"latitude":31.2,"longitude":121.5,"altitude":4}],"kind":"gpx","creator":"阿宁"}
""".data(using: .utf8)!
let oldRoute = try! JSONDecoder().decode(SavedRoute.self, from: oldJSON)
check(oldRoute.id == "old", "old id")
check(oldRoute.name == "旧路线", "old name")
check(oldRoute.points.count == 1, "old points")
check(oldRoute.kind == .gpx, "old kind")
check(oldRoute.creator == "阿宁", "old creator")
check(oldRoute.waypoints.isEmpty, "old waypoints default to empty")
check(oldRoute.gpxFilename == nil, "old file reference defaults to nil")
check(oldRoute.importedAt == nil, "old import time stays nil")
check(oldRoute.cutoffResolved == false, "old route has not read a cutoff")

let legacyPoint = try! JSONDecoder().decode(
    RouteWaypoint.self,
    from: Data("{\"name\":\"CP1\",\"latitude\":1,\"longitude\":2}".utf8)
)
check(legacyPoint.name == "CP1", "old waypoint name")
check(legacyPoint.elevation == nil, "old waypoint elevation stays nil")
check(legacyPoint.cutoff == nil, "old waypoint cutoff stays nil")

let round = SavedRoute(
    id: "new",
    name: "新",
    points: [point(1, 2, 3), point(1.01, 2, 4)],
    kind: .gpx,
    creator: "人",
    waypoints: [RouteWaypoint(name: "CP1", latitude: 1, longitude: 2, elevation: 9)],
    gpxFilename: "gpx/new.gpx"
)
let roundAgain = try! JSONDecoder().decode(SavedRoute.self, from: JSONEncoder().encode(round))
check(roundAgain.waypoints.count == 1, "round trip keeps a waypoint")
check(roundAgain.waypoints.first?.name == "CP1", "round trip name")
check(roundAgain.waypoints.first?.latitude == 1, "round trip latitude")
check(roundAgain.waypoints.first?.longitude == 2, "round trip longitude")
check(roundAgain.waypoints.first?.elevation == 9, "round trip elevation")
check(roundAgain.gpxFilename == "gpx/new.gpx", "round trip file name")
check(roundAgain.points.count == 2, "round trip points")
check(roundAgain.waypoints.first?.cutoff == nil, "round trip without a cutoff stays nil")
check(roundAgain.cutoffResolved == false, "round trip defaults cutoff unresolved")

let timed = SavedRoute(
    id: "timed",
    name: "时",
    points: [point(1, 2, 3)],
    kind: .gpx,
    waypoints: [RouteWaypoint(name: "CP1", latitude: 1, longitude: 2, elevation: 9, cutoff: "08:30")],
    cutoffResolved: true
)
let timedAgain = try! JSONDecoder().decode(SavedRoute.self, from: JSONEncoder().encode(timed))
check(timedAgain.waypoints.first?.cutoff == "08:30", "round trip keeps a cutoff")
check(timedAgain.cutoffResolved, "round trip keeps cutoff resolved")

let climb = [point(0, 0, 0), point(0, 0.01, 10), point(0, 0.02, 4), point(0, 0.03, 8)]
near(RouteStats.ascent(climb), 14, 0.001, "ascent")
near(RouteStats.descent(climb), 6, 0.001, "descent")
check(RouteStats.descent([point(0, 0, 5)]) == 0, "descent of one point")

let preserved = parse("""
<gpx creator="Sky" xmlns="http://www.topografix.com/GPX/1/1">
  <metadata><name>元数据</name><author><name>阿宁</name></author></metadata>
  <trk><name></name><trkseg>
    <trkpt lat="1" lon="1"><ele>2</ele></trkpt>
    <trkpt lat="1" lon="2"><ele>3</ele></trkpt>
  </trkseg></trk>
</gpx>
""")
check(preserved.count == 1, "metadata track still parses")
check(preserved.first?.name == "元数据", "empty track name falls back to metadata")
check(preserved.first?.creator == "阿宁", "author still wins over creator")
check(preserved.first?.points.count == 2, "two track points")
check(preserved.first?.waypoints.isEmpty == true, "unnamed points are not checkpoints")
check(RouteCheckpoints.layout(waypoints: [], points: preserved[0].points).marks.isEmpty, "no fake marks")
check(RouteCheckpoints.layout(waypoints: [], points: preserved[0].points).segments.isEmpty, "no fake segments")

let bare = parse("""
<gpx creator="C"><trk><trkseg>
  <trkpt lat="1" lon="1"/>
  <trkpt lat="2" lon="2"/>
</trkseg></trk></gpx>
""")
check(bare.first?.name == "导入路线", "missing names use the fallback title")
check(bare.first?.creator == "C", "gpx creator is kept")
check(bare.first?.waypoints.isEmpty == true, "a file with no names has no checkpoints")

check(parse("<gpx><wpt lat=\"1\" lon=\"1\"><name>孤</name></wpt></gpx>").isEmpty, "a waypoint alone is not a route")
check(parse("<gpx><trk><name>短</name><trkseg><trkpt lat=\"1\" lon=\"1\"><name>点</name></trkpt></trkseg></trk></gpx>").isEmpty, "one point is not a route")

let numbered = RouteCheckpoints.ordered(
    [
        RouteWaypoint(name: "", latitude: 0, longitude: 0.02, elevation: nil),
        RouteWaypoint(name: "", latitude: 0, longitude: 0, elevation: nil),
    ],
    along: [point(0, 0, 0), point(0, 0.01, 1), point(0, 0.02, 0)]
)
check(numbered.map(\.name) == ["CP1", "CP2"], "empty names are numbered along the route, got \(numbered.map(\.name))")

let skipped = RouteCheckpoints.ordered(
    [
        RouteWaypoint(name: "CP1", latitude: 0, longitude: 0.01, elevation: nil),
        RouteWaypoint(name: "  ", latitude: 0, longitude: 0, elevation: nil),
    ],
    along: [point(0, 0, 0), point(0, 0.01, 1), point(0, 0.02, 0)]
)
check(skipped.map(\.name) == ["CP2", "CP1"], "numbering skips a name the file already used, got \(skipped.map(\.name))")

let orderedTracks = parse("""
<gpx version="1.1" creator="Sky">
  <wpt lat="1" lon="3"><ele>8</ele></wpt>
  <wpt lat="1.0001" lon="1"><name> </name></wpt>
  <trk><name>序</name><trkseg>
    <trkpt lat="1" lon="1"><ele>0</ele></trkpt>
    <trkpt lat="1" lon="2"><ele>5</ele><name>CP1</name></trkpt>
    <trkpt lat="1" lon="3"><ele>1</ele></trkpt>
  </trkseg></trk>
</gpx>
""")
check(orderedTracks.count == 1, "one ordered track")
check(orderedTracks[0].waypoints.map(\.name) == ["CP2", "CP1", "CP3"], "names along the route \(orderedTracks[0].waypoints.map(\.name))")
check(orderedTracks[0].waypoints[0].elevation == nil, "blank waypoint has no elevation")
check(orderedTracks[0].waypoints[1].elevation == 5, "named track point keeps ele")
check(orderedTracks[0].waypoints[2].elevation == 8, "waypoint keeps its own ele")
let orderedLayout = RouteCheckpoints.layout(waypoints: orderedTracks[0].waypoints, points: orderedTracks[0].points)
check(orderedLayout.marks.map(\.name) == ["CP2", "CP1", "CP3"], "marks stay in route order")
check(orderedLayout.marks.allSatisfy { !$0.synthetic }, "start and finish are already waypoints")
check(orderedLayout.marks[0].latitude == 1.0001, "map pin uses the waypoint latitude")
check(orderedLayout.marks[0].longitude == 1, "map pin uses the waypoint longitude")
near(orderedLayout.marks[0].changeMeters, 0, 0.001, "start checkpoint uses the snapped altitude")
near(orderedLayout.marks[1].changeMeters, 5, 0.001, "middle checkpoint uses the snapped altitude")
near(orderedLayout.marks[2].changeMeters, 1, 0.001, "end checkpoint ignores its own ele for the profile")
check(orderedLayout.segments.map(\.title) == ["CP2→CP1", "CP1→CP3"], "segment titles \(orderedLayout.segments.map(\.title))")
near(orderedLayout.segments[0].ascentMeters, 5, 0.001, "first segment climb")
near(orderedLayout.segments[0].descentMeters, 0, 0.001, "first segment descent")
near(orderedLayout.segments[1].ascentMeters, 0, 0.001, "second segment climb")
near(orderedLayout.segments[1].descentMeters, 4, 0.001, "second segment descent")
let orderedTotal = RouteStats.distance(orderedTracks[0].points)
let orderedSum = orderedLayout.segments.reduce(0) { $0 + $1.distanceMeters }
near(orderedSum, orderedTotal, 0.01, "ordered segments cover the route")

let line = [point(0, 0, 100), point(0, 0.01, 150), point(0, 0.02, 120), point(0, 0.03, 180)]
let spring = RouteCheckpoints.layout(
    waypoints: [RouteWaypoint(name: "泉", latitude: 0.0002, longitude: 0.01, elevation: 999)],
    points: line
)
check(spring.marks.map(\.name) == ["起点", "泉", "终点"], "ends are labeled when they are not waypoints \(spring.marks.map(\.name))")
check(spring.marks[0].synthetic && spring.marks[2].synthetic, "start and finish marks are synthetic")
check(!spring.marks[1].synthetic, "the named point is a real waypoint")
check(spring.marks[1].latitude == 0.0002, "泉 is drawn at its own latitude")
check(spring.marks[1].longitude == 0.01, "泉 is drawn at its own longitude")
near(spring.marks[1].changeMeters, 50, 0.001, "泉 uses the snapped track altitude, not its ele")
check(spring.marks[1].snappedIndex == 1, "泉 snaps to the nearest track point")
check(spring.segments.map(\.title) == ["起点→泉", "泉→终点"], "spring segments")
near(spring.segments[0].ascentMeters, 50, 0.001, "spring first climb")
near(spring.segments[0].descentMeters, 0, 0.001, "spring first descent")
near(spring.segments[1].ascentMeters, 60, 0.001, "spring second climb")
near(spring.segments[1].descentMeters, 30, 0.001, "spring second descent")
near(spring.segments.reduce(0) { $0 + $1.distanceMeters }, RouteStats.distance(line), 0.01, "spring segments cover the route")

let split = parse("""
<gpx creator="Sky">
  <wpt lat="10" lon="10"><name>乙点</name></wpt>
  <wpt lat="0" lon="0"><name>甲点</name><ele>4</ele></wpt>
  <trk><name>甲</name><trkseg>
    <trkpt lat="0" lon="0"><ele>1</ele></trkpt>
    <trkpt lat="0" lon="0.01"><ele>3</ele><name>甲中</name></trkpt>
    <trkpt lat="0" lon="0.02"><ele>2</ele></trkpt>
  </trkseg></trk>
  <trk><name>乙</name><trkseg>
    <trkpt lat="10" lon="10"><ele>5</ele></trkpt>
    <trkpt lat="10" lon="10.01"><ele>9</ele></trkpt>
    <trkpt lat="10" lon="10.02"><ele>6</ele></trkpt>
  </trkseg></trk>
</gpx>
""")
check(split.count == 2, "two tracks")
check(split[0].name == "甲" && split[1].name == "乙", "track names")
check(split[0].waypoints.map(\.name) == ["甲点", "甲中"], "甲 keeps its own points \(split[0].waypoints.map(\.name))")
check(split[1].waypoints.map(\.name) == ["乙点"], "乙 gets the nearer waypoint \(split[1].waypoints.map(\.name))")
check(split[0].waypoints[0].elevation == 4, "甲点 elevation")
check(split[0].waypoints[1].elevation == 3, "甲中 elevation")
let jia = RouteCheckpoints.layout(waypoints: split[0].waypoints, points: split[0].points)
let yi = RouteCheckpoints.layout(waypoints: split[1].waypoints, points: split[1].points)
check(jia.marks.map(\.name) == ["甲点", "甲中", "终点"], "甲 already starts on a waypoint \(jia.marks.map(\.name))")
check(yi.marks.map(\.name) == ["乙点", "终点"], "乙 labels the finish \(yi.marks.map(\.name))")
near(yi.segments[0].ascentMeters, 4, 0.001, "乙 climb")
near(yi.segments[0].descentMeters, 3, 0.001, "乙 descent")
near(jia.segments[0].ascentMeters, 2, 0.001, "甲 first climb")
near(jia.segments[1].descentMeters, 1, 0.001, "甲 second descent")

let routeOnly = parse("""
<gpx><rte><name>路</name>
  <rtept lat="1" lon="1"><ele>1</ele><name>起</name></rtept>
  <rtept lat="1" lon="2"><ele>2</ele></rtept>
  <rtept lat="1" lon="3"><ele>0</ele><name>终</name></rtept>
</rte></gpx>
""")
check(routeOnly.count == 1, "route becomes a track")
check(routeOnly[0].name == "路", "route name")
check(routeOnly[0].waypoints.map(\.name) == ["起", "终"], "unnamed rtept is not a checkpoint \(routeOnly[0].waypoints.map(\.name))")
let routeLayout = RouteCheckpoints.layout(waypoints: routeOnly[0].waypoints, points: routeOnly[0].points)
check(routeLayout.marks.map(\.name) == ["起", "终"], "route ends are the named points")
check(routeLayout.segments.map(\.title) == ["起→终"], "one route segment")
near(routeLayout.segments[0].ascentMeters, 1, 0.001, "route climb")
near(routeLayout.segments[0].descentMeters, 2, 0.001, "route descent")

for id in ["check-a", "check-b"] {
    RouteGPXStore.delete(filename: RouteGPXStore.filename(for: id))
}
let payload = Data("same-gpx-bytes".utf8)
let first = RouteGPXStore.save(payload, routeID: "check-a")
let second = RouteGPXStore.save(payload, routeID: "check-b")
check(first == "gpx/check-a.gpx", "first file name \(first ?? "nil")")
check(second == "gpx/check-b.gpx", "second file name \(second ?? "nil")")
check(first != second, "each route gets its own file")
check(RouteGPXStore.load(filename: first) == payload, "first file round trips")
check(RouteGPXStore.load(filename: second) == payload, "second copy has the same bytes")
RouteGPXStore.delete(filename: first)
check(RouteGPXStore.load(filename: first) == nil, "deleted file is gone")
check(RouteGPXStore.load(filename: second) == payload, "the other route keeps its copy")
RouteGPXStore.delete(filename: second)
check(RouteGPXStore.load(filename: second) == nil, "second file deleted")
check(RouteGPXStore.load(filename: nil) == nil, "nil filename does not load")
check(RouteGPXStore.load(filename: "../phone.json") == nil, "parent path is refused")
check(RouteGPXStore.load(filename: "gpx/../../phone.json") == nil, "nested parent path is refused")
check(RouteGPXStore.load(filename: "gpx/phone.json") == nil, "non-gpx name is refused")
RouteGPXStore.delete(filename: "../phone.json")
RouteGPXStore.delete(filename: nil)

check(ElevationScale.bounds([]) == nil, "no elevation bounds")
let ranged = [point(0, 0, 4), point(0, 0.01, 9), point(0, 0.02, 4)]
let rangedBounds = ElevationScale.bounds(ranged)
check(rangedBounds?.low == 4 && rangedBounds?.high == 9, "bounds use this route")
check(ElevationScale.rgb(unit: 0) == .low, "low is green")
check(ElevationScale.rgb(unit: 0.5) == .mid, "middle is yellow")
check(ElevationScale.rgb(unit: 1) == .high, "high is red")
check(ElevationScale.rgb(altitude: 4, low: 4, high: 9) == .low, "route low is green")
check(ElevationScale.rgb(altitude: 6.5, low: 4, high: 9) == .mid, "route middle is yellow")
check(ElevationScale.rgb(altitude: 9, low: 4, high: 9) == .high, "route high is red")
check(ElevationScale.rgb(unit: 0.25) == ElevationRGB.low.mixed(with: .mid, fraction: 0.5), "quarter mixes green and yellow")
check(ElevationScale.unit(altitude: 100, low: 10, high: 10.2) == 0.5, "flat route stays the middle color")
check(ElevationScale.unit(altitude: -5, low: 0, high: 10) == 0, "below the route clamps low")
check(ElevationScale.unit(altitude: 40, low: 0, high: 10) == 1, "above the route clamps high")

let wave = [point(0, 0, 5), point(0, 0.01, 1), point(0, 0.02, 9), point(0, 0.03, 4)]
let profile = RouteStats.altitudeProfile(wave, limit: 2)
check(profile.contains { $0.altitudeMeters == 1 }, "profile keeps the lowest altitude")
check(profile.contains { $0.altitudeMeters == 9 }, "profile keeps the highest altitude")
check(profile.first?.distanceKilometers == 0, "profile starts at the route start")
near(profile.last?.distanceKilometers ?? -1, RouteStats.distance(wave) / 1000, 0.000001, "profile distance is the path")
check(zip(profile, profile.dropFirst()).allSatisfy { $0.distanceKilometers <= $1.distanceKilometers }, "profile distance does not go backwards")

check(RouteKilometers.markers(along: []).isEmpty, "no markers without points")
check(RouteKilometers.markers(along: [point(0, 0, 1)]).isEmpty, "no markers for one point")
let shortHop = [point(0, 0, 1), point(0, 0.001, 2)]
check(RouteStats.distance(shortHop) < 1000, "short hop is under a kilometer")
check(RouteKilometers.markers(along: shortHop).isEmpty, "partial kilometer has no marker")

let start = point(0, 0, 100)
let far = point(0, 0.02, 220)
let back = point(0, 0, 140)
let outAndBack = [start, far, back]
let pathMeters = RouteStats.distance(outAndBack)
let straightMeters = RouteStats.metersBetween(start, back)
check(straightMeters < 1, "out and back ends where it started")
check(pathMeters > 3000, "path is the walked distance")
let markers = RouteKilometers.markers(along: outAndBack)
check(markers.count == Int(pathMeters / 1000), "one marker per completed kilometer \(markers.count)")
check(markers.map(\.kilometer) == Array(1...markers.count), "markers are numbered 1, 2, 3")
check(markers.allSatisfy { $0.distanceMeters == Double($0.kilometer) * 1000 }, "markers sit on whole kilometers")
check(markers.last.map { pathMeters + 0.001 >= $0.distanceMeters } ?? false, "no marker past the path")
check(markers.last.map { pathMeters - $0.distanceMeters < 1000 } ?? false, "the last full kilometer is included")
let outbound = RouteStats.metersBetween(start, far)
let returning = markers.filter { $0.distanceMeters > outbound + 0.5 }
check(!returning.isEmpty, "later kilometers continue on the way back")
check(returning.allSatisfy { $0.longitude < far.longitude && $0.longitude >= start.longitude - 0.0000001 }, "return markers stay on the path")

let leg = RouteStats.metersBetween(start, far)
let span = [start, far]
let spanMarkers = RouteKilometers.markers(along: span)
check(spanMarkers.count == Int(leg / 1000), "long segment still counts path distance")
for marker in spanMarkers {
    let fraction = marker.distanceMeters / leg
    let latitude = start.latitude + (far.latitude - start.latitude) * fraction
    let longitude = start.longitude + (far.longitude - start.longitude) * fraction
    near(marker.latitude, latitude, 0.0000001, "km \(marker.kilometer) latitude")
    near(marker.longitude, longitude, 0.0000001, "km \(marker.kilometer) longitude")
    let altitude = start.altitude + (far.altitude - start.altitude) * fraction
    near(marker.altitude, altitude, 0.001, "km \(marker.kilometer) altitude")
}

func savedRoute(
    id: String,
    name: String,
    kind: SavedRoute.Kind = .gpx,
    file: String? = nil
) -> SavedRoute {
    SavedRoute(
        id: id,
        name: name,
        points: [point(31.2, 121.4, 5), point(31.21, 121.41, 8)],
        kind: kind,
        creator: "阿宁",
        gpxFilename: file
    )
}

var seededList = Database()
seededList.sampleRouteSeeded = true
seededList.routes = [
    savedRoute(id: SavedRoute.sampleGPXID, name: "徐汇滨江", file: "gpx/sample-xuhui-riverside.gpx"),
    savedRoute(id: "user-same-name", name: "徐汇滨江", file: "gpx/user-same-name.gpx"),
    savedRoute(id: "user-trail", name: "Shenxianju trail-30km"),
    savedRoute(id: SavedRoute.presetRunningID, name: "湖滨环线", kind: .presetRunning)
]
let retiredFiles = seededList.retireSeededSampleRoute()
check(retiredFiles == ["gpx/sample-xuhui-riverside.gpx"], "only the seed file is retired")
check(seededList.sampleRouteSeeded, "seed flag stays set after retirement")
check(!seededList.routes.contains { $0.id == SavedRoute.sampleGPXID }, "seed id is removed")
check(seededList.routes.contains { $0.id == "user-same-name" && $0.name == "徐汇滨江" }, "user import named 徐汇滨江 stays")
check(seededList.routes.contains { $0.id == "user-trail" }, "other imported route stays")
check(seededList.routes.contains { $0.kind == .presetRunning }, "preset route stays")

var freshRoutes = Database()
check(freshRoutes.retireSeededSampleRoute().isEmpty, "fresh install has no seed file")
check(freshRoutes.routes.isEmpty, "fresh install does not insert 徐汇滨江")
check(freshRoutes.sampleRouteSeeded, "fresh install records that the sample was retired")

var renamedSeed = Database()
renamedSeed.routes = [savedRoute(id: SavedRoute.sampleGPXID, name: "改过的样本")]
check(renamedSeed.retireSeededSampleRoute().isEmpty, "seed without a stored file returns no filename")
check(renamedSeed.routes.isEmpty, "renamed seed is still removed by id")

var alreadyImported = Database()
alreadyImported.routes = [savedRoute(id: "user-9", name: "导入路线")]
check(alreadyImported.retireSeededSampleRoute().isEmpty, "no seed file when the user already imported")
check(alreadyImported.routes.map(\.id) == ["user-9"], "retire does not insert a sample beside a user route")
check(alreadyImported.sampleRouteSeeded, "flag is set so a later launch cannot insert the sample")

func expectCutoff(_ text: String, _ expected: String?, _ message: String, bare: Bool = false) {
    let actual = bare
        ? RouteCutoff.parse(notes: [], bareTimes: [text])
        : RouteCutoff.parse(notes: [text])
    check(actual == expected, "\(message): \(actual ?? "nil") != \(expected ?? "nil")")
}

expectCutoff("关门时间：08:00", "08:00", "colon cutoff")
expectCutoff("关门时间:8:05", "08:05", "single hour digit")
expectCutoff("关门时间：１４：３０", "14:30", "fullwidth digits")
expectCutoff("关门 14：30", "14:30", "fullwidth colon")
expectCutoff("关门时间14点30分", "14:30", "点分")
expectCutoff("关门时间 9点半", "09:30", "半")
expectCutoff("关门时间下午2:30", "14:30", "afternoon")
expectCutoff("关门时间：下午三点半", "15:30", "chinese afternoon")
expectCutoff("关门时间十五点三十分", "15:30", "chinese hour")
expectCutoff("关门时间：次日1:05", "次日 01:05", "next day")
expectCutoff("关门时间 次日 1:20", "次日 01:20", "next day with space")
expectCutoff("14:30关门", "14:30", "time before keyword")
expectCutoff("关门时间12:00-18:30", "18:30", "range uses the closing time")
expectCutoff("关门时间10:00至14:30", "14:30", "至 range")
expectCutoff("关门时间大约 14:30", "14:30", "大约")
expectCutoff("关门时刻 23:59:30", "23:59:30", "seconds stay when they are not zero")
expectCutoff("关门时间：08:00:00", "08:00", "zero seconds are dropped")
expectCutoff("关门时间 24:00", "24:00", "24:00 is kept")
expectCutoff("Cut-off time: 7:05", "07:05", "english cut-off")
expectCutoff("CUTOFF 18:00", "18:00", "english cutoff")
expectCutoff("关门时间待定", nil, "no time")
expectCutoff("关门", nil, "keyword alone")
expectCutoff("补给：水", nil, "unrelated note")
expectCutoff("集合时间 6:00", nil, "a time without 关门 is not a cutoff")
expectCutoff("开门 6:00", nil, "open time is not a cutoff")
expectCutoff("关门时间 25:00", nil, "hour out of range")
expectCutoff("关门时间 12:99", nil, "minute out of range")
expectCutoff("下午12:00关门", "12:00", "noon stays 12")
expectCutoff("14:30", nil, "bare time in a note is not a cutoff")
expectCutoff("14:30", "14:30", "element named cutoff can be a bare time", bare: true)
expectCutoff("10:00-16:00", "16:00", "bare range uses the end", bare: true)

let cutoffTrack = parse("""
<gpx creator="Sky">
  <wpt lat="0" lon="0"><ele>1</ele><time>2024-11-11T00:00:00Z</time><name>起终点</name><cmt>关门时间：08:00</cmt></wpt>
  <wpt lat="0" lon="0.01"><name>CP1</name><cmt>补给</cmt><desc>关门时间：下午2:30</desc></wpt>
  <wpt lat="0" lon="0.02"><name>CP2</name><desc>无关门</desc><extensions><cutoff>16:00</cutoff></extensions></wpt>
  <trk><name>关门</name><trkseg>
    <trkpt lat="0" lon="0"><ele>100</ele></trkpt>
    <trkpt lat="0" lon="0.01"><ele>150</ele><name>中</name><cmt>关门 9点半</cmt></trkpt>
    <trkpt lat="0" lon="0.02"><ele>120</ele></trkpt>
    <trkpt lat="0" lon="0.03"><ele>180</ele></trkpt>
  </trkseg></trk>
</gpx>
""")
check(cutoffTrack.count == 1, "cutoff file is one track")
check(cutoffTrack[0].waypoints.map(\.name) == ["起终点", "中", "CP1", "CP2"], "cutoff names \(cutoffTrack[0].waypoints.map(\.name))")
check(cutoffTrack[0].waypoints.map(\.cutoff) == ["08:00", "09:30", "14:30", "16:00"], "cutoff values \(String(describing: cutoffTrack[0].waypoints.map(\.cutoff)))")
let orderedCutoff = RouteCheckpoints.ordered(cutoffTrack[0].waypoints, along: cutoffTrack[0].points)
check(orderedCutoff.map(\.cutoff) == ["08:00", "09:30", "14:30", "16:00"], "ordering keeps cutoff")

let noTime = parse("""
<gpx><wpt lat="1" lon="1"><name>点</name><time>2024-01-01T08:00:00Z</time><cmt>集合时间 6:00</cmt></wpt>
<trk><name>无</name><trkseg>
  <trkpt lat="1" lon="1"><ele>1</ele></trkpt>
  <trkpt lat="1" lon="2"><ele>2</ele></trkpt>
</trkseg></trk></gpx>
""")
check(noTime.first?.waypoints.count == 1, "named waypoint still imports")
check(noTime.first?.waypoints.first?.cutoff == nil, "gps time and 集合时间 are not a cutoff")

let lineForProgress = [point(0, 0, 100), point(0, 0.01, 150), point(0, 0.02, 120), point(0, 0.03, 180)]
let progress = RouteCheckpoints.progress(
    waypoints: [
        RouteWaypoint(name: "终", latitude: 0, longitude: 0.03, elevation: nil, cutoff: nil),
        RouteWaypoint(name: "起", latitude: 0, longitude: 0, elevation: nil, cutoff: "08:00"),
        RouteWaypoint(name: "泉", latitude: 0, longitude: 0.01, elevation: nil, cutoff: "  "),
    ],
    points: lineForProgress
)
check(progress.map(\.name) == ["起", "泉", "终"], "progress follows the track \(progress.map(\.name))")
check(progress[0].cutoff == "08:00", "progress keeps cutoff")
check(progress[1].cutoff == nil, "blank cutoff is nil")
check(progress[2].cutoff == nil, "missing cutoff is nil")
near(progress[0].distanceMeters, 0, 0.001, "start distance")
near(progress[0].ascentMeters, 0, 0.001, "start ascent")
near(progress[0].descentMeters, 0, 0.001, "start descent")
let middleSlice = Array(lineForProgress[0...1])
near(progress[1].distanceMeters, RouteStats.distance(middleSlice), 0.01, "middle distance")
near(progress[1].ascentMeters, RouteStats.ascent(middleSlice), 0.001, "middle ascent")
near(progress[1].descentMeters, RouteStats.descent(middleSlice), 0.001, "middle descent")
near(progress[2].distanceMeters, RouteStats.distance(lineForProgress), 0.01, "end distance matches the totals")
near(progress[2].ascentMeters, RouteStats.ascent(lineForProgress), 0.001, "end ascent matches the totals")
near(progress[2].descentMeters, RouteStats.descent(lineForProgress), 0.001, "end descent matches the totals")
check(progress[2].ascentMeters > progress[1].ascentMeters, "later point keeps the earlier climb")
let onlySpring = RouteCheckpoints.progress(
    waypoints: [RouteWaypoint(name: "泉", latitude: 0.0002, longitude: 0.01, elevation: 999)],
    points: lineForProgress
)
check(onlySpring.map(\.name) == ["泉"], "progress does not invent start or finish")
check(RouteCheckpoints.progress(waypoints: [], points: lineForProgress).isEmpty, "no waypoints means no progress rows")
let dropped = RouteCheckpoints.progress(
    waypoints: [RouteWaypoint(name: "坏", latitude: 999, longitude: 0, elevation: nil, cutoff: "01:00")],
    points: lineForProgress
)
check(dropped.isEmpty, "an invalid waypoint is not a card")

let backfillXML = """
<gpx creator="Sky">
  <wpt lat="0" lon="0"><name>起</name><cmt>关门时间：08:00</cmt></wpt>
  <wpt lat="0" lon="0.02"><name>终</name><desc>补给点</desc></wpt>
  <trk><name>回填</name><trkseg>
    <trkpt lat="0" lon="0"><ele>1</ele></trkpt>
    <trkpt lat="0" lon="0.01"><ele>4</ele></trkpt>
    <trkpt lat="0" lon="0.02"><ele>2</ele></trkpt>
  </trkseg></trk>
</gpx>
"""
let backfillParsed = parse(backfillXML)
check(backfillParsed[0].waypoints.map(\.cutoff) == ["08:00", nil], "parsed backfill cutoffs \(String(describing: backfillParsed[0].waypoints.map(\.cutoff)))")
let backfillName = RouteGPXStore.save(Data(backfillXML.utf8), routeID: "cutoff-backfill")
var stripped = backfillParsed[0].waypoints
stripped[0].cutoff = nil
var backfillRoutes = [
    SavedRoute(
        id: "cutoff-backfill",
        name: "改名",
        points: backfillParsed[0].points,
        kind: .gpx,
        waypoints: stripped,
        gpxFilename: backfillName
    )
]
RouteGPXStore.mergeCutoffs(into: &backfillRoutes)
check(backfillRoutes[0].waypoints[0].cutoff == "08:00", "backfill copies cutoff from the file")
check(backfillRoutes[0].waypoints[1].cutoff == nil, "backfill does not invent a cutoff")
check(backfillRoutes[0].waypoints[0].name == "起", "backfill keeps the saved name")
check(backfillRoutes[0].cutoffResolved, "a read file is resolved")
check(backfillRoutes[0].points.count == 3, "backfill does not replace the track")
RouteGPXStore.delete(filename: backfillName)
RouteGPXStore.mergeCutoffs(into: &backfillRoutes)
check(backfillRoutes[0].waypoints[0].cutoff == "08:00", "a resolved route is not parsed again")

var renamedPoint = stripped
renamedPoint[0].name = "起点"
renamedPoint[0].cutoff = nil
let renamedFile = RouteGPXStore.save(Data(backfillXML.utf8), routeID: "cutoff-rename")
var renamedRoutes = [
    SavedRoute(
        id: "cutoff-rename",
        name: "回填",
        points: backfillParsed[0].points,
        kind: .gpx,
        waypoints: renamedPoint,
        gpxFilename: renamedFile
    )
]
RouteGPXStore.mergeCutoffs(into: &renamedRoutes)
check(renamedRoutes[0].waypoints[0].cutoff == "08:00", "same place still receives cutoff when the name differs")
check(renamedRoutes[0].waypoints[0].name == "起点", "a different saved name is kept")
RouteGPXStore.delete(filename: renamedFile)

let emptyFile = RouteGPXStore.save(Data(backfillXML.utf8), routeID: "cutoff-empty")
var emptyRoutes = [
    SavedRoute(
        id: "cutoff-empty",
        name: "回填",
        points: backfillParsed[0].points,
        kind: .gpx,
        gpxFilename: emptyFile
    )
]
RouteGPXStore.mergeCutoffs(into: &emptyRoutes)
check(emptyRoutes[0].waypoints.isEmpty, "backfill does not add waypoints")
check(emptyRoutes[0].cutoffResolved, "a file with no saved waypoints is still resolved")
RouteGPXStore.delete(filename: emptyFile)

let plainXML = """
<gpx><wpt lat="0" lon="0"><name>泉</name><desc>补给点</desc></wpt>
<trk><name>无门</name><trkseg>
  <trkpt lat="0" lon="0"><ele>1</ele></trkpt>
  <trkpt lat="0" lon="0.02"><ele>2</ele></trkpt>
</trkseg></trk></gpx>
"""
let plainName = RouteGPXStore.save(Data(plainXML.utf8), routeID: "cutoff-none")
let plainParsed = parse(plainXML)
var plainRoutes = [
    SavedRoute(
        id: "cutoff-none",
        name: "无门",
        points: plainParsed[0].points,
        kind: .gpx,
        waypoints: [RouteWaypoint(name: "泉", latitude: 0, longitude: 0, elevation: nil)],
        gpxFilename: plainName
    )
]
RouteGPXStore.mergeCutoffs(into: &plainRoutes)
check(plainRoutes[0].waypoints[0].cutoff == nil, "a file without 关门 stays blank")
check(plainRoutes[0].cutoffResolved, "a file without 关门 is not read on every launch")
RouteGPXStore.delete(filename: plainName)

var kept = plainRoutes
kept[0].cutoffResolved = false
kept[0].waypoints[0].cutoff = "09:00"
let keptName = RouteGPXStore.save(Data(backfillXML.utf8), routeID: "cutoff-keep")
kept[0].gpxFilename = keptName
kept[0].points = backfillParsed[0].points
RouteGPXStore.mergeCutoffs(into: &kept)
check(kept[0].waypoints[0].cutoff == "09:00", "an existing cutoff is not replaced")
RouteGPXStore.delete(filename: keptName)

let splitXML = """
<gpx creator="Sky">
  <wpt lat="0" lon="0"><name>甲</name><cmt>关门 08:00</cmt></wpt>
  <wpt lat="1" lon="1"><name>乙</name><cmt>关门 18:00</cmt></wpt>
  <trk><name>甲线</name><trkseg>
    <trkpt lat="0" lon="0"><ele>1</ele></trkpt>
    <trkpt lat="0" lon="0.01"><ele>2</ele></trkpt>
  </trkseg></trk>
  <trk><name>乙线</name><trkseg>
    <trkpt lat="1" lon="1"><ele>3</ele></trkpt>
    <trkpt lat="1" lon="1.01"><ele>4</ele></trkpt>
  </trkseg></trk>
</gpx>
"""
let splitParsed = parse(splitXML)
check(splitParsed.count == 2, "two tracks for cutoff backfill")
let splitName = RouteGPXStore.save(Data(splitXML.utf8), routeID: "cutoff-split")
func cleared(_ waypoints: [RouteWaypoint]) -> [RouteWaypoint] {
    waypoints.map { waypoint in
        var copy = waypoint
        copy.cutoff = nil
        return copy
    }
}
var splitRoutes = [
    SavedRoute(
        id: "cutoff-split-a",
        name: "甲线",
        points: splitParsed[0].points,
        kind: .gpx,
        waypoints: cleared(splitParsed[0].waypoints),
        gpxFilename: splitName
    ),
    SavedRoute(
        id: "cutoff-split-b",
        name: "乙线",
        points: splitParsed[1].points,
        kind: .gpx,
        waypoints: cleared(splitParsed[1].waypoints),
        gpxFilename: splitName
    )
]
RouteGPXStore.mergeCutoffs(into: &splitRoutes)
check(splitRoutes[0].waypoints.map(\.cutoff) == ["08:00"], "first track keeps its own cutoff \(String(describing: splitRoutes[0].waypoints.map(\.cutoff)))")
check(splitRoutes[1].waypoints.map(\.cutoff) == ["18:00"], "second track keeps its own cutoff \(String(describing: splitRoutes[1].waypoints.map(\.cutoff)))")
RouteGPXStore.delete(filename: splitName)

var missingFile = [
    SavedRoute(
        id: "cutoff-missing",
        name: "缺",
        points: backfillParsed[0].points,
        kind: .gpx,
        waypoints: [RouteWaypoint(name: "起", latitude: 0, longitude: 0, elevation: nil)],
        gpxFilename: "gpx/cutoff-missing.gpx"
    )
]
RouteGPXStore.mergeCutoffs(into: &missingFile)
check(missingFile[0].waypoints[0].cutoff == nil, "a missing file does not invent a cutoff")
check(missingFile[0].cutoffResolved == false, "a missing file can be read later")

if failures.isEmpty {
    print("route-checkpoint-check ok")
} else {
    for failure in failures {
        print("FAIL \(failure)")
    }
    exit(1)
}
