import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

struct GPXTrack: Hashable {
    var name: String
    var creator: String
    var points: [GeoPoint]
    /// Waypoints for this track, in route order. Empty names are already CP1, CP2, …
    var waypoints: [RouteWaypoint] = []
}

enum GPXFile {
    static func parse(_ data: Data) -> [GPXTrack] {
        let parser = GPXParser()
        parser.parse(data)
        return parser.tracks
    }
}

private final class GPXParser: NSObject, XMLParserDelegate {
    private(set) var tracks: [GPXTrack] = []

    private var stack: [String] = []
    private var buffer = ""
    private var gpxCreator = ""
    private var metadataName = ""
    private var authorName = ""
    private var trackPoints: [GeoPoint] = []
    private var trackName = ""
    private var trackNamed: [RouteWaypoint] = []
    private var routePoints: [GeoPoint] = []
    private var routeName = ""
    private var routeNamed: [RouteWaypoint] = []
    private var looseWaypoints: [RouteWaypoint] = []
    private var openPoint: GeoPoint?
    private var openPointName = ""
    private var openElevation: Double?

    private let fractionalTime: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let internetTime: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    func parse(_ data: Data) {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        _ = parser.parse()
        distributeWaypoints()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        buffer = ""
        let name = Self.localName(elementName, qualified: qName)
        switch name {
        case "gpx":
            let creator = attributeDict["creator"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !creator.isEmpty { gpxCreator = creator }
        case "trk":
            if !stack.contains("trk") {
                trackPoints = []
                trackName = ""
                trackNamed = []
            }
        case "rte":
            if !stack.contains("rte") {
                routePoints = []
                routeName = ""
                routeNamed = []
            }
        case "trkpt", "rtept", "wpt":
            beginPoint(attributeDict)
        default:
            break
        }
        stack.append(name)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, foundIgnorableWhitespace whitespace: String) {
        buffer += whitespace
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = Self.localName(elementName, qualified: qName)
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        let index = stack.lastIndex(of: name)
        let parent = index.flatMap { $0 > 0 ? stack[$0 - 1] : nil }
        if let index {
            stack.removeSubrange(index...)
        }
        switch name {
        case "ele":
            guard var point = openPoint, let value = Double(text), value.isFinite else { return }
            point.altitude = value
            openPoint = point
            openElevation = value
        case "time":
            guard parent == "trkpt" || parent == "rtept", var point = openPoint, let date = date(from: text) else { return }
            point.timestamp = date
            openPoint = point
        case "name":
            guard !text.isEmpty else { return }
            switch parent {
            case "author":
                if authorName.isEmpty { authorName = text }
            case "metadata":
                if metadataName.isEmpty { metadataName = text }
            case "trk":
                if trackName.isEmpty { trackName = text }
            case "rte":
                if routeName.isEmpty { routeName = text }
            case "trkpt", "rtept", "wpt":
                if openPointName.isEmpty { openPointName = text }
            default:
                break
            }
        case "trkpt":
            if let openPoint {
                trackPoints.append(openPoint)
                if let named = namedPoint(from: openPoint) {
                    trackNamed.append(named)
                }
            }
            clearPoint()
        case "rtept":
            if let openPoint {
                routePoints.append(openPoint)
                if let named = namedPoint(from: openPoint) {
                    routeNamed.append(named)
                }
            }
            clearPoint()
        case "wpt":
            if let openPoint {
                looseWaypoints.append(waypoint(from: openPoint, name: openPointName))
            }
            clearPoint()
        case "trk":
            if !stack.contains("trk") {
                commit(name: trackName, points: trackPoints, named: trackNamed)
                trackPoints = []
                trackName = ""
                trackNamed = []
            }
        case "rte":
            if !stack.contains("rte") {
                commit(name: routeName, points: routePoints, named: routeNamed)
                routePoints = []
                routeName = ""
                routeNamed = []
            }
        default:
            break
        }
    }

    private func beginPoint(_ attributes: [String: String]) {
        openPoint = Self.makePoint(attributes)
        openPointName = ""
        openElevation = Self.attributeElevation(attributes)
    }

    private func namedPoint(from point: GeoPoint) -> RouteWaypoint? {
        let trimmed = openPointName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return waypoint(from: point, name: trimmed)
    }

    private func waypoint(from point: GeoPoint, name: String) -> RouteWaypoint {
        RouteWaypoint(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            latitude: point.latitude,
            longitude: point.longitude,
            elevation: openElevation
        )
    }

    private func clearPoint() {
        openPoint = nil
        openPointName = ""
        openElevation = nil
    }

    private func commit(name: String, points: [GeoPoint], named: [RouteWaypoint]) {
        guard points.count >= 2 else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? (metadataName.isEmpty ? "导入路线" : metadataName) : trimmed
        let person = authorName.isEmpty ? gpxCreator : authorName
        tracks.append(GPXTrack(name: title, creator: person, points: points, waypoints: named))
    }

    /// `<wpt>` elements are not inside a track. One track keeps all of them.
    /// Several tracks each keep the waypoints nearest to that line. Named trkpt/rtept stay on their own track.
    private func distributeWaypoints() {
        guard !tracks.isEmpty else { return }
        if tracks.count == 1 {
            tracks[0].waypoints.append(contentsOf: looseWaypoints)
        } else {
            for waypoint in looseWaypoints {
                let index = nearestTrack(for: waypoint)
                tracks[index].waypoints.append(waypoint)
            }
        }
        looseWaypoints = []
        for index in tracks.indices {
            tracks[index].waypoints = RouteCheckpoints.ordered(tracks[index].waypoints, along: tracks[index].points)
        }
    }

    private func nearestTrack(for waypoint: RouteWaypoint) -> Int {
        var best = 0
        var bestDistance = Double.greatestFiniteMagnitude
        let probe = GeoPoint(latitude: waypoint.latitude, longitude: waypoint.longitude, altitude: 0, timestamp: nil)
        for (index, track) in tracks.enumerated() {
            for point in track.points {
                let distance = RouteStats.flatMeters(probe, point)
                if distance < bestDistance {
                    bestDistance = distance
                    best = index
                }
            }
        }
        return best
    }

    private func date(from text: String) -> Date? {
        if let date = fractionalTime.date(from: text) { return date }
        return internetTime.date(from: text)
    }

    private static func attributeElevation(_ attributes: [String: String]) -> Double? {
        guard let raw = attributes["ele"], let value = Double(raw), value.isFinite else { return nil }
        return value
    }

    private static func makePoint(_ attributes: [String: String]) -> GeoPoint? {
        guard let latitude = Double(attributes["lat"] ?? ""),
              let longitude = Double(attributes["lon"] ?? ""),
              latitude.isFinite, longitude.isFinite,
              abs(latitude) <= 90, abs(longitude) <= 180 else { return nil }
        var altitude = 0.0
        if let raw = attributes["ele"], let value = Double(raw), value.isFinite {
            altitude = value
        }
        return GeoPoint(latitude: latitude, longitude: longitude, altitude: altitude, timestamp: nil)
    }

    private static func localName(_ elementName: String, qualified qName: String?) -> String {
        let raw = ((qName?.isEmpty == false ? qName : nil) ?? elementName).lowercased()
        guard let colon = raw.lastIndex(of: ":") else { return raw }
        return String(raw[raw.index(after: colon)...])
    }
}
