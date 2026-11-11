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
    /// Comment, description, and other note text on the point that is open.
    private var openNotes: [String] = []
    /// Text of an element whose name itself means cutoff, such as `<cutoff>`.
    private var openBareCutoffs: [String] = []

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
        let insidePoint = stack.contains { $0 == "trkpt" || $0 == "rtept" || $0 == "wpt" }
        let index = stack.lastIndex(of: name)
        let parent = index.flatMap { $0 > 0 ? stack[$0 - 1] : nil }
        if let index {
            stack.removeSubrange(index...)
        }
        capturePointText(element: name, text: text, insidePoint: insidePoint)
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
        openNotes = []
        openBareCutoffs = []
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
            elevation: openElevation,
            cutoff: RouteCutoff.parse(notes: openNotes, bareTimes: openBareCutoffs)
        )
    }

    /// Keeps comment and description text, plus a cutoff element, while a point is open.
    /// A GPS `<time>` is not a cutoff. A name is kept only when it itself states 关门.
    private func capturePointText(element name: String, text: String, insidePoint: Bool) {
        guard insidePoint, !text.isEmpty else { return }
        if name == "trkpt" || name == "rtept" || name == "wpt" { return }
        let folded = name.lowercased()
        if Self.bareCutoffNames.contains(folded) {
            openBareCutoffs.append(text)
            return
        }
        let foldedText = text.lowercased()
        let mentionsCutoff = text.contains("关门")
            || foldedText.contains("cutoff")
            || foldedText.contains("cut-off")
            || foldedText.contains("cut off")
        let noteName = Self.noteNames.contains(folded)
        if noteName || (mentionsCutoff && folded != "ele" && folded != "time" && folded != "name") || (folded == "name" && mentionsCutoff) {
            openNotes.append(text)
        }
    }

    private static let noteNames: Set<String> = ["cmt", "desc", "comment", "description", "notes", "note"]
    private static let bareCutoffNames: Set<String> = ["cutoff", "cut-off", "closingtime", "closetime", "关门时间", "关门"]

    private func clearPoint() {
        openPoint = nil
        openPointName = ""
        openElevation = nil
        openNotes = []
        openBareCutoffs = []
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

/// Reads a race cutoff from GPX comment, description, or similar text.
/// A time with no 关门 / cutoff keyword is not a cutoff, unless the element name itself means cutoff.
enum RouteCutoff {
    static func parse(notes: [String], bareTimes: [String] = []) -> String? {
        for note in notes {
            if let found = scan(normalize(note)) { return found }
        }
        for text in bareTimes {
            let normalized = normalize(text)
            if let found = scan(normalized) { return found }
            if let found = bareTime(normalized) { return found }
        }
        return nil
    }

    private static let keywords = [
        "关门时间", "关门时刻", "关门",
        "cutoff time", "cut-off time", "cut off time",
        "cutoff", "cut-off", "cut off"
    ]

    private static let digits: [Character: Int] = [
        "零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
        "五": 5, "六": 6, "七": 7, "八": 8, "九": 9
    ]

    private enum Period {
        case none, early, morning, noon, afternoon, evening
    }

    private struct ParsedTime {
        var display: String
        var end: Int
    }

    private static func scan(_ text: String) -> String? {
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            if let length = keywordLength(chars, index) {
                let after = index + length
                if let time = timeAfter(chars, after) { return time }
                if let time = timeBefore(chars, index) { return time }
                index = after
                continue
            }
            index += 1
        }
        return nil
    }

    private static func bareTime(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let chars = Array(trimmed)
        guard let parsed = parseTime(chars, 0) else { return nil }
        if let later = rangeEnd(chars, parsed.end) {
            var end = later.end
            skipSeparators(&end, chars, limit: 4)
            if end == chars.count { return later.display }
        }
        var end = parsed.end
        skipSeparators(&end, chars, limit: 4)
        guard end == chars.count else { return nil }
        return parsed.display
    }

    private static func keywordLength(_ chars: [Character], _ index: Int) -> Int? {
        let folded = String(chars[index...]).lowercased()
        for keyword in keywords where folded.hasPrefix(keyword) {
            return keyword.count
        }
        return nil
    }

    private static func timeAfter(_ chars: [Character], _ start: Int) -> String? {
        var index = start
        skipLeadIn(&index, chars)
        guard let first = parseTime(chars, index) else { return nil }
        if let later = rangeEnd(chars, first.end) { return later.display }
        return first.display
    }

    private static func timeBefore(_ chars: [Character], _ keywordStart: Int) -> String? {
        var end = keywordStart
        var skipped = 0
        while end > 0, skipped < 6, isSeparator(chars[end - 1]) {
            end -= 1
            skipped += 1
        }
        let window = max(0, end - 18)
        var cursor = window
        while cursor < end {
            if let parsed = parseTime(chars, cursor), parsed.end == end {
                return parsed.display
            }
            cursor += 1
        }
        return nil
    }

    private static func rangeEnd(_ chars: [Character], _ start: Int) -> ParsedTime? {
        var index = start
        while index < chars.count, chars[index].isWhitespace { index += 1 }
        guard index < chars.count else { return nil }
        if chars[index] == "-" || chars[index] == "–" || chars[index] == "—" || chars[index] == "~" || chars[index] == "～" {
            index += 1
        } else if hasPrefix(chars, index, "到") || hasPrefix(chars, index, "至") {
            index += 1
        } else {
            return nil
        }
        while index < chars.count, chars[index].isWhitespace { index += 1 }
        return parseTime(chars, index)
    }

    private static func parseTime(_ chars: [Character], _ start: Int) -> ParsedTime? {
        var index = start
        var nextDay = false
        if hasPrefix(chars, index, "次日") {
            index += 2
            nextDay = true
            skipSeparators(&index, chars, limit: 2)
        } else if hasPrefix(chars, index, "第二天") {
            index += 3
            nextDay = true
            skipSeparators(&index, chars, limit: 2)
        }
        var period = Period.none
        if hasPrefix(chars, index, "凌晨") {
            period = .early
            index += 2
        } else if hasPrefix(chars, index, "上午") {
            period = .morning
            index += 2
        } else if hasPrefix(chars, index, "中午") {
            period = .noon
            index += 2
        } else if hasPrefix(chars, index, "下午") {
            period = .afternoon
            index += 2
        } else if hasPrefix(chars, index, "晚上") {
            period = .evening
            index += 2
        }
        if period != .none { skipSeparators(&index, chars, limit: 2) }

        let hourStart = index
        var hour: Int?
        if let arabic = readNumber(&index, chars) {
            hour = arabic
        } else {
            index = hourStart
            hour = readChineseNumber(&index, chars)
        }
        guard let hour else { return nil }
        guard index < chars.count else { return nil }
        let mark = chars[index]
        if mark == ":" || mark == "：" {
            index += 1
            guard let minute = readNumber(&index, chars) ?? readChineseAfterMark(&index, chars) else { return nil }
            var second: Int?
            if index < chars.count, chars[index] == ":" || chars[index] == "：" {
                let saved = index
                index += 1
                if let value = readNumber(&index, chars), value >= 0, value <= 59 {
                    second = value
                } else {
                    index = saved
                }
            }
            return finish(hour: hour, minute: minute, second: second, period: period, nextDay: nextDay, end: index)
        }
        if mark == "点" || mark == "时" {
            index += 1
            var minute = 0
            if index < chars.count, chars[index] == "半" {
                minute = 30
                index += 1
            } else if let value = readNumber(&index, chars) ?? readChineseAfterMark(&index, chars), value >= 0, value <= 59 {
                minute = value
                if index < chars.count, chars[index] == "分" { index += 1 }
            }
            var second: Int?
            if index < chars.count {
                let saved = index
                if let value = readNumber(&index, chars), value >= 0, value <= 59, index < chars.count, chars[index] == "秒" {
                    index += 1
                    second = value
                } else {
                    index = saved
                }
            }
            return finish(hour: hour, minute: minute, second: second, period: period, nextDay: nextDay, end: index)
        }
        return nil
    }

    private static func readChineseAfterMark(_ index: inout Int, _ chars: [Character]) -> Int? {
        let saved = index
        guard let value = readChineseNumber(&index, chars) else {
            index = saved
            return nil
        }
        return value
    }

    private static func finish(
        hour: Int,
        minute: Int,
        second: Int?,
        period: Period,
        nextDay: Bool,
        end: Int
    ) -> ParsedTime? {
        guard minute >= 0, minute <= 59 else { return nil }
        if let second, second < 0 || second > 59 { return nil }
        guard let adjusted = adjust(hour: hour, period: period) else { return nil }
        if adjusted == 24 {
            guard minute == 0, (second ?? 0) == 0 else { return nil }
        } else if adjusted < 0 || adjusted > 23 {
            return nil
        }
        return ParsedTime(display: clock(hour: adjusted, minute: minute, second: second, nextDay: nextDay), end: end)
    }

    private static func adjust(hour: Int, period: Period) -> Int? {
        switch period {
        case .none:
            return hour
        case .early, .morning:
            if hour == 12 { return 0 }
            return hour
        case .afternoon, .evening:
            if hour < 12 { return hour + 12 }
            return hour
        case .noon:
            if hour == 12 { return 12 }
            if hour >= 1, hour < 11 { return hour + 12 }
            return hour
        }
    }

    private static func clock(hour: Int, minute: Int, second: Int?, nextDay: Bool) -> String {
        let body: String
        if let second, second != 0 {
            body = String(format: "%02d:%02d:%02d", hour, minute, second)
        } else {
            body = String(format: "%02d:%02d", hour, minute)
        }
        return nextDay ? "次日 \(body)" : body
    }

    private static func skipLeadIn(_ index: inout Int, _ chars: [Character]) {
        skipSeparators(&index, chars, limit: 6)
        if hasPrefix(chars, index, "大约") {
            index += 2
            skipSeparators(&index, chars, limit: 3)
        }
    }

    private static func skipSeparators(_ index: inout Int, _ chars: [Character], limit: Int) {
        var skipped = 0
        while index < chars.count, skipped < limit, isSeparator(chars[index]) {
            index += 1
            skipped += 1
        }
    }

    private static func isSeparator(_ character: Character) -> Bool {
        if character.isWhitespace { return true }
        switch character {
        case ":", "：", "为", "是", "约", "~", "～", "-", "—", "–", "到", "至",
             "[", "]", "【", "】", "(", ")", "（", "）", "\"", "“", "”", "、", ",", "，", ".", "。":
            return true
        default:
            return false
        }
    }

    private static func readNumber(_ index: inout Int, _ chars: [Character]) -> Int? {
        guard index < chars.count, chars[index].isASCII, chars[index].isNumber else { return nil }
        var value = 0
        var count = 0
        while index < chars.count, count < 2, chars[index].isASCII, let digit = chars[index].wholeNumberValue {
            value = value * 10 + digit
            index += 1
            count += 1
        }
        return count > 0 ? value : nil
    }

    private static func readChineseNumber(_ index: inout Int, _ chars: [Character]) -> Int? {
        guard index < chars.count else { return nil }
        if chars[index] == "十" {
            index += 1
            if index < chars.count, let ones = digits[chars[index]] {
                index += 1
                return 10 + ones
            }
            return 10
        }
        guard let head = digits[chars[index]] else { return nil }
        index += 1
        if index < chars.count, chars[index] == "十" {
            index += 1
            if index < chars.count, let ones = digits[chars[index]] {
                index += 1
                return head * 10 + ones
            }
            return head * 10
        }
        return head
    }

    private static func hasPrefix(_ chars: [Character], _ index: Int, _ prefix: String) -> Bool {
        guard index < chars.count else { return false }
        return String(chars[index...]).hasPrefix(prefix)
    }

    private static func normalize(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0xFF10...0xFF19:
                if let ascii = UnicodeScalar(scalar.value - 0xFF10 + 0x30) {
                    result.unicodeScalars.append(ascii)
                }
            case 0xFF1A:
                result.append(":")
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
