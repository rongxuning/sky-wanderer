import Foundation

/// On-disk names for record-list map thumbnails under Application Support.
///
/// Files live in `record-thumbs/`. The list reads these instead of opening a
/// live `MKMapView` for every card, which was jetsam-killing cold launches.
enum RecordListThumbnailFile {
    static let folder = "record-thumbs"
    /// Bumps when the plate camera or start-pin drawing changes so old JPEGs
    /// are not reused after a tighter track fit.
    static let plateVersion = "2"

    /// Relative path: `record-thumbs/<id>-<basemap>-<side>-v<version>.jpg`.
    static func relativePath(id: UUID, basemapToken: String, side: Int) -> String {
        "\(folder)/\(id.uuidString)-\(basemapToken)-\(side)-v\(plateVersion).jpg"
    }

    /// Prefix used to delete every size/basemap variant for one workout.
    static func idPrefix(_ id: UUID) -> String {
        "\(id.uuidString)-"
    }
}
