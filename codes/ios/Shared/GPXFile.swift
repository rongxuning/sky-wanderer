import Foundation

struct GPXTrack: Hashable {
    var name: String
    var creator: String
    var points: [GeoPoint]
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
    private var routePoints: [GeoPoint] = []
    private var routeName = ""
    private var openPoint: GeoPoint?

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
        parser.parse()
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
            }
        case "rte":
            if !stack.contains("rte") {
                routePoints = []
                routeName = ""
            }
        case "trkpt", "rtept":
            openPoint = Self.makePoint(attributeDict)
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
            default:
                break
            }
        case "trkpt":
            if let openPoint { trackPoints.append(openPoint) }
            openPoint = nil
        case "rtept":
            if let openPoint { routePoints.append(openPoint) }
            openPoint = nil
        case "trk":
            if !stack.contains("trk") {
                commit(name: trackName, points: trackPoints)
                trackPoints = []
                trackName = ""
            }
        case "rte":
            if !stack.contains("rte") {
                commit(name: routeName, points: routePoints)
                routePoints = []
                routeName = ""
            }
        default:
            break
        }
    }

    private func commit(name: String, points: [GeoPoint]) {
        guard points.count >= 2 else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? (metadataName.isEmpty ? "导入路线" : metadataName) : trimmed
        let person = authorName.isEmpty ? gpxCreator : authorName
        tracks.append(GPXTrack(name: title, creator: person, points: points))
    }

    private func date(from text: String) -> Date? {
        if let date = fractionalTime.date(from: text) { return date }
        return internetTime.date(from: text)
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
