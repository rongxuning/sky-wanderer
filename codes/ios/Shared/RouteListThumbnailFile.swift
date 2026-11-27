import Foundation

/// On-disk names for route-list map thumbnails under Application Support.
///
/// Files live in `route-thumbs/`. The list reads these instead of opening a
/// live `MKMapView` for every card.
enum RouteListThumbnailFile {
    static let folder = "route-thumbs"
    /// Bumps when the plate camera or track ink changes so old JPEGs are not reused.
    static let plateVersion = "1"

    /// Relative path: `route-thumbs/<id>-<basemap>-<side>-v<version>.jpg`.
    static func relativePath(id: String, basemapToken: String, side: Int) -> String {
        "\(folder)/\(fileToken(id))-\(basemapToken)-\(side)-v\(plateVersion).jpg"
    }

    /// Prefix used to delete every size/basemap variant for one route.
    static func idPrefix(_ id: String) -> String {
        "\(fileToken(id))-"
    }

    /// Route ids are usually UUID strings; strip path separators for the file name.
    private static func fileToken(_ id: String) -> String {
        id
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }
}
