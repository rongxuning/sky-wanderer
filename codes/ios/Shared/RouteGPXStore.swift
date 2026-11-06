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
