import UIKit

/// JPEG map plates for the records list, under Application Support `record-thumbs/`.
///
/// Write once when a workout is saved or when a gentle backfill runs. The list
/// only reads these (plus an in-memory cache). It does not open MapKit per card.
enum RecordListThumbnailStore {
    static func exists(id: UUID, basemapToken: String, side: Int) -> Bool {
        guard let url = try? url(id: id, basemapToken: basemapToken, side: side) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    static func load(id: UUID, basemapToken: String, side: Int) -> UIImage? {
        guard let url = try? url(id: id, basemapToken: basemapToken, side: side),
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else {
            return nil
        }
        return image
    }

    static func loadAsync(id: UUID, basemapToken: String, side: Int) async -> UIImage? {
        await Task.detached(priority: .utility) {
            load(id: id, basemapToken: basemapToken, side: side)
        }.value
    }

    static func existsAsync(id: UUID, basemapToken: String, side: Int) async -> Bool {
        await Task.detached(priority: .utility) {
            exists(id: id, basemapToken: basemapToken, side: side)
        }.value
    }

    @discardableResult
    static func save(_ image: UIImage, id: UUID, basemapToken: String, side: Int) -> Bool {
        guard let data = image.jpegData(compressionQuality: 0.82) else { return false }
        guard let url = try? url(id: id, basemapToken: basemapToken, side: side) else { return false }
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

    static func deleteAll(for id: UUID) {
        guard let folder = try? AppFiles.directory()
            .appendingPathComponent(RecordListThumbnailFile.folder, isDirectory: true) else {
            return
        }
        let prefix = RecordListThumbnailFile.idPrefix(id)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
            return
        }
        for name in names where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    private static func url(id: UUID, basemapToken: String, side: Int) throws -> URL {
        try AppFiles.file(
            RecordListThumbnailFile.relativePath(id: id, basemapToken: basemapToken, side: side)
        )
    }
}
