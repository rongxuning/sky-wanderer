import UIKit

/// JPEG map plates for the records list, under Application Support `record-thumbs/`.
///
/// Write once when a workout is saved or when a gentle backfill runs. The list
/// only reads these (plus an in-memory cache). It does not open MapKit per card.
/// Solid-black failed captures are never stored; a bad file on disk is deleted
/// on load so backfill can warm again.
enum RecordListThumbnailStore {
    static func exists(id: UUID, basemapToken: String, sizeToken: String) -> Bool {
        load(id: id, basemapToken: basemapToken, sizeToken: sizeToken) != nil
    }

    static func load(id: UUID, basemapToken: String, sizeToken: String) -> UIImage? {
        guard let url = try? url(id: id, basemapToken: basemapToken, sizeToken: sizeToken),
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else {
            return nil
        }
        guard RecordListThumbnailQuality.isUsable(image) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return image
    }

    static func loadAsync(id: UUID, basemapToken: String, sizeToken: String) async -> UIImage? {
        await Task.detached(priority: .utility) {
            load(id: id, basemapToken: basemapToken, sizeToken: sizeToken)
        }.value
    }

    static func existsAsync(id: UUID, basemapToken: String, sizeToken: String) async -> Bool {
        await Task.detached(priority: .utility) {
            exists(id: id, basemapToken: basemapToken, sizeToken: sizeToken)
        }.value
    }

    @discardableResult
    static func save(_ image: UIImage, id: UUID, basemapToken: String, sizeToken: String) -> Bool {
        guard RecordListThumbnailQuality.isUsable(image) else { return false }
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

    private static func url(id: UUID, basemapToken: String, sizeToken: String) throws -> URL {
        try AppFiles.file(
            RecordListThumbnailFile.relativePath(id: id, basemapToken: basemapToken, sizeToken: sizeToken)
        )
    }
}

extension RecordListThumbnailQuality {
    /// Samples a downscaled bitmap. Failed offscreen MapKit plates are near-black
    /// or an unpainted light backdrop.
    static func isUsable(_ image: UIImage) -> Bool {
        guard let stats = lumaStats(image) else { return false }
        return isUsable(
            meanLuma: stats.meanLuma,
            darkPixelFraction: stats.darkPixelFraction,
            lumaSpread: stats.lumaSpread
        )
    }

    static func lumaStats(_ image: UIImage) -> (meanLuma: Double, darkPixelFraction: Double, lumaSpread: Double)? {
        guard let cgImage = image.cgImage else { return nil }
        let width = min(cgImage.width, 64)
        let height = min(cgImage.height, 64)
        guard width > 0, height > 0 else { return nil }
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return sample(
            bytes: bytes,
            bytesPerPixel: bytesPerPixel,
            width: width,
            height: height,
            step: 1
        )
    }
}
