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

if failures.isEmpty {
    print("route-checkpoint-check ok")
} else {
    for failure in failures {
        print("FAIL \(failure)")
    }
    exit(1)
}
