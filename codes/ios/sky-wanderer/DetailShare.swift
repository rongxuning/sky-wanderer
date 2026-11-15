import Photos
import SwiftUI
import UIKit

enum DetailShareKind {
    /// Map plus the first-screen summary card.
    case screen
    /// Map, summary, and every section below the fold.
    case full
}

enum DetailPhotoSaveResult {
    case saved
    case denied
    case failed
}

enum DetailPhotoLibrary {
    static func save(_ image: UIImage) async -> DetailPhotoSaveResult {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return .denied }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { success, _ in
                continuation.resume(returning: success ? .saved : .failed)
            }
        }
    }
}

/// Builds a share image without the map overlay buttons.
/// The map is the same `MKMapView` and `TrackOverlay` as the screen, drawn offscreen.
/// The summary and charts are the SwiftUI views the page shows.
enum DetailShareImage {
    @MainActor
    static func mapImage(
        route: [GeoPoint],
        size: CGSize
    ) async -> UIImage? {
        guard size.width > 1, size.height > 1 else { return nil }
        return await TrackMapImage.render(route: route, size: size, overlap: SkyTheme.Radius.sheet)
    }

    @MainActor
    static func render<Content: View>(_ content: Content, width: CGFloat) -> UIImage? {
        let scale = currentScale
        guard width > 1 else { return nil }
        let renderer = ImageRenderer(
            content: content
                .frame(width: width, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.colorScheme, .light)
        )
        renderer.scale = scale
        renderer.isOpaque = false
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        guard let image = renderer.uiImage, image.size.width > 1, image.size.height > 1 else {
            return nil
        }
        return image
    }

    static func assemble(map: UIImage, summary: UIImage, charts: UIImage?, overlap: CGFloat) -> UIImage {
        let scale = map.scale > 0 ? map.scale : 3
        let width = max(map.size.width, summary.size.width, charts?.size.width ?? 0)
        let overlapUsed = min(max(0, overlap), map.size.height * 0.45, summary.size.height * 0.45)
        let chartsHeight = charts?.size.height ?? 0
        let height = map.size.height - overlapUsed + summary.size.height + chartsHeight
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.image { _ in
            UIColor(red: 245 / 255, green: 245 / 255, blue: 247 / 255, alpha: 1).setFill()
            UIBezierPath(rect: CGRect(x: 0, y: 0, width: width, height: height)).fill()
            map.draw(in: CGRect(x: 0, y: 0, width: width, height: map.size.height))
            let summaryY = map.size.height - overlapUsed
            summary.draw(in: CGRect(x: 0, y: summaryY, width: width, height: summary.size.height))
            if let charts {
                charts.draw(in: CGRect(x: 0, y: summaryY + summary.size.height, width: width, height: charts.size.height))
            }
        }
    }

    private static var currentScale: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scale = scenes.first?.screen.scale ?? 0
        return scale > 0 ? scale : 3
    }
}
