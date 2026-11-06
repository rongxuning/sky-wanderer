import MapKit
import Photos
import SwiftUI
import UIKit

/// Apple map styles for the workout detail page. Stored on this phone.
enum DetailMapStyle: String, CaseIterable, Identifiable {
    case standard
    case quiet
    case imagery
    case hybrid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "标准"
        case .quiet: return "简洁（少标注）"
        case .imagery: return "卫星"
        case .hybrid: return "混合（卫星加路名）"
        }
    }

    var mapStyle: MapStyle {
        switch self {
        case .standard:
            return .standard
        case .quiet:
            return .standard(emphasis: .muted, pointsOfInterest: .excludingAll)
        case .imagery:
            return .imagery
        case .hybrid:
            return .hybrid
        }
    }

    private static let storageKey = "sky.detailMapStyle"

    static var stored: DetailMapStyle {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
              let style = DetailMapStyle(rawValue: raw) else {
            return .standard
        }
        return style
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.storageKey)
    }

    fileprivate var snapshotMapType: MKMapType {
        switch self {
        case .standard: return .standard
        case .quiet: return .mutedStandard
        case .imagery: return .satellite
        case .hybrid: return .hybrid
        }
    }
}

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
/// MapKit views do not paint inside `ImageRenderer`, so the map is an `MKMapSnapshotter`
/// image with the route drawn on top. The summary and charts are the same SwiftUI
/// views the page shows, rendered offscreen and stacked under the map.
enum DetailShareImage {
    @MainActor
    static func mapImage(
        route: [GeoPoint],
        style: DetailMapStyle,
        size: CGSize
    ) async -> UIImage? {
        let scale = currentScale
        guard size.width > 1, size.height > 1 else { return nil }
        return await snapshot(route: route, style: style, size: size, scale: scale, overlap: SkyTheme.Radius.sheet)
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

    private static func snapshot(
        route: [GeoPoint],
        style: DetailMapStyle,
        size: CGSize,
        scale: CGFloat,
        overlap: CGFloat
    ) async -> UIImage? {
        let options = MKMapSnapshotter.Options()
        options.region = region(for: route)
        options.size = size
        options.scale = scale
        options.mapType = style.snapshotMapType
        if style == .quiet {
            options.pointOfInterestFilter = .excludingAll
        }
        let snapshotter = MKMapSnapshotter(options: options)
        do {
            let shot = try await snapshotter.start()
            return draw(shot, route: route, size: size, scale: scale, overlap: overlap)
        } catch {
            return nil
        }
    }

    private static func region(for route: [GeoPoint]) -> MKCoordinateRegion {
        if let fitted = GeoFit.region(route.map(\.coordinate)) {
            return fitted
        }
        return MKCoordinateRegion(
            center: MapOrigin.fallback.coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
        )
    }

    private static func draw(
        _ snapshot: MKMapSnapshotter.Snapshot,
        route: [GeoPoint],
        size: CGSize,
        scale: CGFloat,
        overlap: CGFloat
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            snapshot.image.draw(in: CGRect(origin: .zero, size: size))
            let blue = UIColor(red: 30 / 255, green: 136 / 255, blue: 254 / 255, alpha: 1)
            guard route.count >= 2 else {
                drawEmptyCaption(in: size, overlap: overlap)
                return
            }
            let path = UIBezierPath()
            for (index, point) in route.enumerated() {
                let location = snapshot.point(for: point.coordinate)
                if index == 0 {
                    path.move(to: location)
                } else {
                    path.addLine(to: location)
                }
            }
            blue.setStroke()
            path.lineWidth = 5
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            path.stroke()
            mark(snapshot.point(for: route[0].coordinate), square: false, color: blue)
            mark(snapshot.point(for: route[route.count - 1].coordinate), square: true, color: blue)
        }
    }

    private static func mark(_ center: CGPoint, square: Bool, color: UIColor) {
        let side: CGFloat = 14
        let rect = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
        let path: UIBezierPath
        if square {
            path = UIBezierPath(roundedRect: rect, cornerRadius: 3)
        } else {
            path = UIBezierPath(ovalIn: rect)
        }
        color.setFill()
        path.fill()
        UIColor.white.setStroke()
        path.lineWidth = 2
        path.stroke()
    }

    private static func drawEmptyCaption(in size: CGSize, overlap: CGFloat) {
        let text = "这次没有轨迹" as NSString
        let font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor(red: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 1)
        ]
        let textSize = text.size(withAttributes: attributes)
        let horizontalPad: CGFloat = 12
        let verticalPad: CGFloat = 8
        let bubble = CGSize(width: textSize.width + horizontalPad * 2, height: textSize.height + verticalPad * 2)
        let origin = CGPoint(
            x: (size.width - bubble.width) / 2,
            y: size.height - overlap - 12 - bubble.height
        )
        let rect = CGRect(origin: origin, size: bubble)
        UIColor.white.withAlphaComponent(0.94).setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: bubble.height / 2).fill()
        text.draw(
            at: CGPoint(x: rect.minX + horizontalPad, y: rect.minY + verticalPad),
            withAttributes: attributes
        )
    }
}
