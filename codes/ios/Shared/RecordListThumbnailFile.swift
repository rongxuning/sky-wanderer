import Foundation

/// On-disk names for record-list map thumbnails under Application Support.
///
/// Files live in `record-thumbs/`. The list reads these instead of opening a
/// live `MKMapView` for every card, which was jetsam-killing cold launches.
enum RecordListThumbnailFile {
    static let folder = "record-thumbs"
    /// Bumps when the plate camera, track ink, or start-pin drawing changes so
    /// old JPEGs are not reused after a tighter track fit or color change.
    /// v5 drops solid-black failed Tianditu / Metal captures that covered the track.
    /// v6 also drops unpainted light-backdrop plates that hid the start pin.
    static let plateVersion = "6"

    /// Relative path: `record-thumbs/<id>-<basemap>-<sizeToken>-v<version>.jpg`.
    /// `sizeToken` is `88x82` (or legacy integer side for older files).
    static func relativePath(id: UUID, basemapToken: String, sizeToken: String) -> String {
        "\(folder)/\(id.uuidString)-\(basemapToken)-\(sizeToken)-v\(plateVersion).jpg"
    }

    /// Legacy integer-side path used by older checks and call sites.
    static func relativePath(id: UUID, basemapToken: String, side: Int) -> String {
        relativePath(id: id, basemapToken: basemapToken, sizeToken: "\(side)")
    }

    /// Prefix used to delete every size/basemap variant for one workout.
    static func idPrefix(_ id: UUID) -> String {
        "\(id.uuidString)-"
    }
}
