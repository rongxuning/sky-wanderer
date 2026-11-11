import Foundation

/// Original GPX bytes for one saved route, under Application Support `gpx/<id>.gpx`.
/// A route imported before this existed has no file. It also has no checkpoints until the user imports it again.
enum RouteGPXStore {
    static func filename(for routeID: String) -> String {
        "gpx/\(safeID(routeID)).gpx"
    }

    /// Writes a copy of the imported bytes. Returns the relative filename, or nil if the write fails.
    @discardableResult
    static func save(_ data: Data, routeID: String) -> String? {
        let name = filename(for: routeID)
        guard let url = try? url(forRelative: name) else { return nil }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    /// Reads a previously stored GPX so a later pass can parse it again.
    static func load(filename: String?) -> Data? {
        guard let url = try? url(forRelative: filename) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func delete(filename: String?) {
        guard let url = try? url(forRelative: filename) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Copies 关门时间 from a GPX that is still on disk onto waypoints that do not have one.
    /// Does not add waypoints, and does not invent a time the file does not contain.
    /// A route whose file was read is marked `cutoffResolved` so the next launch does not parse it again.
    /// A missing file stays unresolved. Waypoints that already have a cutoff are left as saved.
    static func mergeCutoffs(into routes: inout [SavedRoute]) {
        for index in routes.indices {
            guard routes[index].kind == .gpx, !routes[index].cutoffResolved else { continue }
            guard let filename = routes[index].gpxFilename else { continue }
            guard let data = load(filename: filename) else { continue }
            let tracks = GPXFile.parse(data)
            guard let track = matchingTrack(route: routes[index], tracks: tracks) else { continue }
            routes[index].waypoints = applying(parsed: track.waypoints, to: routes[index].waypoints)
            routes[index].cutoffResolved = true
        }
    }

    private static func matchingTrack(route: SavedRoute, tracks: [GPXTrack]) -> GPXTrack? {
        let matches = tracks.filter { sameGeometry($0, route) }
        if let named = matches.first(where: { $0.name == route.name }) { return named }
        if matches.count == 1 { return matches[0] }
        return tracks.first { $0.name == route.name && endpointsClose($0, route) }
    }

    private static func sameGeometry(_ track: GPXTrack, _ route: SavedRoute) -> Bool {
        guard track.points.count == route.points.count, track.points.count >= 2 else { return false }
        return endpointsClose(track, route)
    }

    private static func endpointsClose(_ track: GPXTrack, _ route: SavedRoute) -> Bool {
        guard let trackStart = track.points.first, let routeStart = route.points.first,
              let trackEnd = track.points.last, let routeEnd = route.points.last else { return false }
        return close(trackStart, routeStart) && close(trackEnd, routeEnd)
    }

    private static func close(_ start: GeoPoint, _ end: GeoPoint) -> Bool {
        abs(start.latitude - end.latitude) < 0.00001 && abs(start.longitude - end.longitude) < 0.00001
    }

    private static func applying(parsed: [RouteWaypoint], to saved: [RouteWaypoint]) -> [RouteWaypoint] {
        var result = saved
        var used = Set<Int>()
        for index in result.indices where result[index].cutoff == nil {
            guard let match = parsed.enumerated().first(where: { offset, candidate in
                !used.contains(offset) && candidate.cutoff != nil && sameWaypoint(result[index], candidate)
            }) else { continue }
            result[index].cutoff = match.element.cutoff
            used.insert(match.offset)
        }
        guard result.count == parsed.count else { return result }
        for index in result.indices where result[index].cutoff == nil && !used.contains(index) {
            guard let cutoff = parsed[index].cutoff, near(result[index], parsed[index]) else { continue }
            result[index].cutoff = cutoff
            used.insert(index)
        }
        return result
    }

    private static func sameWaypoint(_ saved: RouteWaypoint, _ parsed: RouteWaypoint) -> Bool {
        let savedName = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedName = parsed.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !savedName.isEmpty, savedName == parsedName else { return false }
        return near(saved, parsed)
    }

    private static func near(_ saved: RouteWaypoint, _ parsed: RouteWaypoint) -> Bool {
        abs(saved.latitude - parsed.latitude) < 0.0001 && abs(saved.longitude - parsed.longitude) < 0.0001
    }

    private static func url(forRelative name: String?) throws -> URL {
        guard let name, !name.isEmpty else { throw CocoaError(.fileNoSuchFile) }
        let file = URL(fileURLWithPath: name).lastPathComponent
        guard file.hasSuffix(".gpx"), file != ".gpx", !file.contains("..") else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let stored = "gpx/\(file)"
        guard name == stored || name == file else { throw CocoaError(.fileReadInvalidFileName) }
        let folder = try AppFiles.directory().appendingPathComponent("gpx", isDirectory: true)
        return folder.appendingPathComponent(file)
    }

    private static func safeID(_ routeID: String) -> String {
        let cleaned = String(routeID.map { character -> Character in
            if character.isLetter || character.isNumber || character == "-" { return character }
            return "-"
        })
        return cleaned.isEmpty ? "route" : cleaned
    }
}
