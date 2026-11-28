import UIKit

/// JPEG map plates for the routes list, under Application Support `route-thumbs/`.
///
/// Write once when a route is imported or when a gentle backfill runs. The list
/// only reads these (plus an in-memory cache). It does not open MapKit per card.
enum RouteListThumbnailStore {
    static func exists(id: String, basemapToken: String, sizeToken: String) -> Bool {
        guard let url = try? url(id: id, basemapToken: basemapToken, sizeToken: sizeToken) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    static func load(id: String, basemapToken: String, sizeToken: String) -> UIImage? {
        guard let url = try? url(id: id, basemapToken: basemapToken, sizeToken: sizeToken),
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else {
            return nil
        }
        return image
    }

    static func loadAsync(id: String, basemapToken: String, sizeToken: String) async -> UIImage? {
        await Task.detached(priority: .utility) {
            load(id: id, basemapToken: basemapToken, sizeToken: sizeToken)
        }.value
    }

    static func existsAsync(id: String, basemapToken: String, sizeToken: String) async -> Bool {
        await Task.detached(priority: .utility) {
            exists(id: id, basemapToken: basemapToken, sizeToken: sizeToken)
        }.value
    }

    @discardableResult
    static func save(_ image: UIImage, id: String, basemapToken: String, sizeToken: String) -> Bool {
        guard let data = image.jpegData(compressionQuality: 0.82) else { return false }
        guard let url = try? url(id: id, basemapToken: basemapToken, sizeToken: sizeToken) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func deleteAll(for id: String) {
        guard let folder = try? AppFiles.directory()
            .appendingPathComponent(RouteListThumbnailFile.folder, isDirectory: true) else {
            return
        }
        let prefix = RouteListThumbnailFile.idPrefix(id)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
            return
        }
        for name in names where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    private static func url(id: String, basemapToken: String, sizeToken: String) throws -> URL {
        try AppFiles.file(
            RouteListThumbnailFile.relativePath(id: id, basemapToken: basemapToken, sizeToken: sizeToken)
        )
    }
}
