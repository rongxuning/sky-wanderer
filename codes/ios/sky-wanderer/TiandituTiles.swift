import Foundation
import MapKit
import UIKit

/// Official Tianditu layers. Only Web Mercator `_w` is used with MapKit's XYZ grid.
/// `vector` / `vectorNotes` are an isolated hook and are not installed by any screen.
enum TiandituLayer: String {
    case terrain = "ter"
    case terrainNotes = "cta"
    case vector = "vec"
    case vectorNotes = "cva"

    var pathName: String { "\(rawValue)_w" }

    /// The hillshade replaces Apple's tiles. Annotation layers draw on top of it.
    var replacesMap: Bool { self == .terrain }

    var cacheFolder: String { rawValue }
}

enum TiandituStack {
    /// Default basemap: terrain hillshade plus terrain names.
    case terrain
    /// Not selected anywhere. Kept so a later switch does not invent a second client.
    case vector

    var layers: [TiandituLayer] {
        switch self {
        case .terrain:
            return [.terrain, .terrainNotes]
        case .vector:
            return [.vector, .vectorNotes]
        }
    }
}

enum TiandituTileFailure {
    case rateLimited
    case timeout
    case other
}

/// How many WMTS loads are still running. Share capture waits until this is idle.
enum TiandituTileActivity {
    private static let lock = NSLock()
    private static var inFlight = 0

    static func begin() {
        lock.lock()
        inFlight += 1
        lock.unlock()
    }

    static func end() {
        lock.lock()
        inFlight = max(0, inFlight - 1)
        lock.unlock()
    }

    static var busy: Bool {
        lock.lock()
        defer { lock.unlock() }
        return inFlight > 0
    }
}

enum TiandituWMTS {
    /// Matrix `w` is Web Mercator. Official WMTS text puts row 0 on the northwest
    /// tile and counts rows southward, which is `MKTileOverlayPath.y`. Do not
    /// invert it. The `_c` lon/lat matrix uses a different origin and is not requested.
    /// `TILEMATRIX` is the web zoom (level 1 is 2×2). Level 0 is omitted; the overlay
    /// starts at z = 1.
    static func tileRow(pathY: Int) -> Int { pathY }

    static func tileColumn(pathX: Int) -> Int { pathX }

    static func url(layer: TiandituLayer, z: Int, x: Int, y: Int, token: String) -> URL? {
        guard !token.isEmpty, z >= 0, x >= 0, y >= 0 else { return nil }
        let mixed = x &* 31 &+ y
        let host = (mixed % 8 + 8) % 8
        var components = URLComponents()
        components.scheme = "https"
        components.host = "t\(host).tianditu.gov.cn"
        components.path = "/\(layer.pathName)/wmts"
        components.queryItems = [
            URLQueryItem(name: "SERVICE", value: "WMTS"),
            URLQueryItem(name: "REQUEST", value: "GetTile"),
            URLQueryItem(name: "VERSION", value: "1.0.0"),
            URLQueryItem(name: "LAYER", value: layer.rawValue),
            URLQueryItem(name: "STYLE", value: "default"),
            URLQueryItem(name: "TILEMATRIXSET", value: "w"),
            URLQueryItem(name: "FORMAT", value: "tiles"),
            URLQueryItem(name: "TILEMATRIX", value: String(z)),
            URLQueryItem(name: "TILEROW", value: String(tileRow(pathY: y))),
            URLQueryItem(name: "TILECOL", value: String(tileColumn(pathX: x))),
            URLQueryItem(name: "tk", value: token)
        ]
        return components.url
    }
}

enum TiandituDiskCache {
    private static let lock = NSLock()

    static func read(layer: TiandituLayer, z: Int, x: Int, y: Int) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let url = fileURL(layer: layer, z: z, x: x, y: y) else { return nil }
        guard let data = try? Data(contentsOf: url), TiandituImage.isRaster(data) else { return nil }
        return data
    }

    static func write(layer: TiandituLayer, z: Int, x: Int, y: Int, data: Data) {
        guard TiandituImage.isRaster(data), let url = fileURL(layer: layer, z: z, x: x, y: y) else { return }
        lock.lock()
        defer { lock.unlock() }
        let folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func fileURL(layer: TiandituLayer, z: Int, x: Int, y: Int) -> URL? {
        guard let root = try? AppFiles.directory() else { return nil }
        return root
            .appendingPathComponent("tianditu", isDirectory: true)
            .appendingPathComponent(layer.cacheFolder, isDirectory: true)
            .appendingPathComponent(String(z), isDirectory: true)
            .appendingPathComponent(String(x), isDirectory: true)
            .appendingPathComponent("\(y).img")
    }
}

enum TiandituImage {
    static func isRaster(_ data: Data) -> Bool {
        if data.count > 8, data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) { return true }
        if data.count > 3, data.prefix(3) == Data([0xFF, 0xD8, 0xFF]) { return true }
        return false
    }
}

enum TiandituTileLoader {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = [
            "Accept": "image/png,image/jpeg"
        ]
        return URLSession(configuration: configuration)
    }()

    static func load(layer: TiandituLayer, z: Int, x: Int, y: Int, token: String) async -> (Data?, TiandituTileFailure?) {
        if let cached = TiandituDiskCache.read(layer: layer, z: z, x: x, y: y) {
            return (cached, nil)
        }
        guard let url = TiandituWMTS.url(layer: layer, z: z, x: x, y: y, token: token) else {
            return (nil, .other)
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("image/png,image/jpeg", forHTTPHeaderField: "Accept")
        TiandituTileActivity.begin()
        defer { TiandituTileActivity.end() }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 429 { return (nil, .rateLimited) }
            if status == 200, TiandituImage.isRaster(data) {
                TiandituDiskCache.write(layer: layer, z: z, x: x, y: y, data: data)
                return (data, nil)
            }
            return (nil, .other)
        } catch let error as URLError where error.code == .timedOut {
            return (nil, .timeout)
        } catch {
            return (nil, .other)
        }
    }
}

/// WMTS GetTile wrapped so MapKit can treat it like any other tile overlay.
/// Displayed tiles are cached under `tianditu/`. Nothing prefetches a corridor.
final class TiandituTileOverlay: MKTileOverlay {
    let layer: TiandituLayer
    private let token: String

    init(layer: TiandituLayer, token: String) {
        self.layer = layer
        self.token = token
        super.init(urlTemplate: nil)
        canReplaceMapContent = layer.replacesMap
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = 1
        maximumZ = 18
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let layer = self.layer
        let token = self.token
        let z = path.z
        let x = path.x
        let y = path.y
        Task {
            let loaded = await TiandituTileLoader.load(layer: layer, z: z, x: x, y: y, token: token)
            if let failure = loaded.1 {
                SkyBasemapCenter.shared.noteFailure(failure)
                result(nil, TiandituLoadError())
                return
            }
            result(loaded.0, nil)
        }
    }
}

struct TiandituLoadError: Error {}
