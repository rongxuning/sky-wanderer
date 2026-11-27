import MapKit
import UIKit

enum TrackPaint {
    /// Sky primary `#1E88FE`. Start, live, record, library, and share.
    static let primary = UIColor(red: 30.0 / 255, green: 136.0 / 255, blue: 254.0 / 255, alpha: 1)
    /// Record-list thumbnail track `#1E7DD6`.
    static let recordList = UIColor(red: 30.0 / 255, green: 125.0 / 255, blue: 214.0 / 255, alpha: 1)
    /// Planned line on the live map, so it stays distinct from the recording.
    static let planned = UIColor(red: 142.0 / 255, green: 142.0 / 255, blue: 147.0 / 255, alpha: 1)
    static let casing = UIColor.white.withAlphaComponent(0.92)
    static let casingPoints: CGFloat = 8
    static let solidInnerPoints: CGFloat = 4.5
    /// List stroke; no white casing so the blue reads as one solid line.
    static let recordListInnerPoints: CGFloat = 5
    static let recordListCasingPoints: CGFloat = 0
    static let elevationInnerPoints: CGFloat = 4
}

enum TrackStyle {
    case solid(UIColor)
    /// Record-list thumbnail: `#1E7DD6` stroke without a white casing.
    case recordList
    /// Route detail. Green (0.18, 0.78, 0.22) → yellow → red on this route's own altitudes.
    case elevation
}

struct ElevationTrackRun {
    var coordinates: [CLLocationCoordinate2D]
    var color: UIColor
}

enum ElevationTrack {
    private static let steps = 48

    static func make(points: [GeoPoint]) -> [ElevationTrackRun] {
        guard points.count >= 2, let bounds = ElevationScale.bounds(points) else { return [] }
        let vertices = coloredVertices(points, bounds: bounds)
        guard let first = vertices.first else { return [] }
        var runs: [ElevationTrackRun] = []
        var coordinates: [CLLocationCoordinate2D] = [first.coordinate]
        var runBucket = first.bucket
        func flush() {
            guard coordinates.count >= 2 else { return }
            runs.append(ElevationTrackRun(coordinates: coordinates, color: color(for: runBucket)))
        }
        for vertex in vertices.dropFirst() {
            if vertex.bucket != runBucket {
                flush()
                coordinates = [coordinates.last ?? vertex.coordinate, vertex.coordinate]
                runBucket = vertex.bucket
            } else {
                coordinates.append(vertex.coordinate)
            }
        }
        flush()
        return runs
    }

    private static func coloredVertices(
        _ points: [GeoPoint],
        bounds: (low: Double, high: Double)
    ) -> [(coordinate: CLLocationCoordinate2D, bucket: Int)] {
        var vertices: [(coordinate: CLLocationCoordinate2D, bucket: Int)] = []
        vertices.append((points[0].coordinate, bucket(points[0].altitude, bounds: bounds)))
        for index in 1..<points.count {
            let previous = points[index - 1]
            let point = points[index]
            let from = bucket(previous.altitude, bounds: bounds)
            let to = bucket(point.altitude, bounds: bounds)
            let gap = abs(to - from)
            if gap > 1 {
                for step in 1..<gap {
                    let fraction = Double(step) / Double(gap)
                    let altitude = previous.altitude + (point.altitude - previous.altitude) * fraction
                    vertices.append((interpolate(previous, point, fraction), bucket(altitude, bounds: bounds)))
                }
            }
            vertices.append((point.coordinate, to))
        }
        return vertices
    }

    private static func interpolate(_ start: GeoPoint, _ end: GeoPoint, _ fraction: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: start.latitude + (end.latitude - start.latitude) * fraction,
            longitude: start.longitude + (end.longitude - start.longitude) * fraction
        )
    }

    private static func bucket(_ altitude: Double, bounds: (low: Double, high: Double)) -> Int {
        let unit = ElevationScale.unit(altitude: altitude, low: bounds.low, high: bounds.high)
        let index = Int((unit * Double(steps - 1)).rounded())
        return min(steps - 1, max(0, index))
    }

    private static func color(for bucket: Int) -> UIColor {
        let unit = Double(bucket) / Double(max(steps - 1, 1))
        let rgb = ElevationScale.rgb(unit: unit)
        return UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }
}

/// White casing plus an inner stroke. MapKit polylines cannot pair those, so every
/// phone map uses this overlay, including the system-map fallback.
final class TrackOverlay: NSObject, MKOverlay {
    struct Run {
        var mapPoints: [MKMapPoint]
        var color: UIColor
        var bounds: MKMapRect
    }

    let casing: [MKMapPoint]
    let runs: [Run]
    let innerWidth: CGFloat
    let casingWidth: CGFloat
    let boundingMapRect: MKMapRect
    let coordinate: CLLocationCoordinate2D

    init(points: [GeoPoint], style: TrackStyle) {
        let source = points.filter { $0.latitude.isFinite && $0.longitude.isFinite }
        var built: [ElevationTrackRun]
        switch style {
        case .solid(let color):
            innerWidth = TrackPaint.solidInnerPoints
            casingWidth = TrackPaint.casingPoints
            if source.count >= 2 {
                built = [ElevationTrackRun(coordinates: source.map(\.coordinate), color: color)]
            } else {
                built = []
            }
        case .recordList:
            innerWidth = TrackPaint.recordListInnerPoints
            casingWidth = TrackPaint.recordListCasingPoints
            if source.count >= 2 {
                built = [ElevationTrackRun(coordinates: source.map(\.coordinate), color: TrackPaint.recordList)]
            } else {
                built = []
            }
        case .elevation:
            innerWidth = TrackPaint.elevationInnerPoints
            casingWidth = TrackPaint.casingPoints
            built = ElevationTrack.make(points: source)
            if built.isEmpty, source.count >= 2 {
                let rgb = ElevationRGB.mid
                built = [
                    ElevationTrackRun(
                        coordinates: source.map(\.coordinate),
                        color: UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
                    )
                ]
            }
        }
        casing = source.map { MKMapPoint($0.coordinate) }
        var runs: [Run] = []
        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        func absorb(_ mapPoint: MKMapPoint) {
            minX = min(minX, mapPoint.x)
            maxX = max(maxX, mapPoint.x)
            minY = min(minY, mapPoint.y)
            maxY = max(maxY, mapPoint.y)
        }
        for mapPoint in casing { absorb(mapPoint) }
        for piece in built {
            let mapPoints = piece.coordinates.map { MKMapPoint($0) }
            guard let first = mapPoints.first, mapPoints.count >= 2 else { continue }
            var left = first.x
            var right = first.x
            var top = first.y
            var bottom = first.y
            for mapPoint in mapPoints {
                left = min(left, mapPoint.x)
                right = max(right, mapPoint.x)
                top = min(top, mapPoint.y)
                bottom = max(bottom, mapPoint.y)
                absorb(mapPoint)
            }
            runs.append(
                Run(
                    mapPoints: mapPoints,
                    color: piece.color,
                    bounds: MKMapRect(x: left, y: top, width: max(right - left, 1), height: max(bottom - top, 1))
                )
            )
        }
        self.runs = runs
        if minX <= maxX, casing.count >= 2 {
            let pad = 512.0
            let rect = MKMapRect(
                x: minX - pad,
                y: minY - pad,
                width: max(maxX - minX, 1) + pad * 2,
                height: max(maxY - minY, 1) + pad * 2
            )
            boundingMapRect = rect
            coordinate = MKMapPoint(x: rect.midX, y: rect.midY).coordinate
        } else {
            boundingMapRect = .world
            coordinate = source.first?.coordinate ?? CLLocationCoordinate2D()
        }
        super.init()
    }
}

final class TrackOverlayRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let track = overlay as? TrackOverlay, track.casing.count >= 2 else { return }
        let scale = max(zoomScale, 0.000001)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        guard let first = track.casing.first else { return }
        if track.casingWidth > 0 {
            context.beginPath()
            context.setStrokeColor(TrackPaint.casing.cgColor)
            context.setLineWidth(track.casingWidth / scale)
            context.move(to: point(for: first))
            for mapPoint in track.casing.dropFirst() {
                context.addLine(to: point(for: mapPoint))
            }
            context.strokePath()
        }

        let pad = 64 / Double(scale)
        let visible = MKMapRect(
            x: mapRect.origin.x - pad,
            y: mapRect.origin.y - pad,
            width: mapRect.size.width + pad * 2,
            height: mapRect.size.height + pad * 2
        )
        context.setLineWidth(track.innerWidth / scale)
        for run in track.runs where run.bounds.intersects(visible) {
            guard let start = run.mapPoints.first else { continue }
            context.beginPath()
            context.setStrokeColor(run.color.cgColor)
            context.move(to: point(for: start))
            for mapPoint in run.mapPoints.dropFirst() {
                context.addLine(to: point(for: mapPoint))
            }
            context.strokePath()
        }
    }
}

enum TrackMapDrawing {
    static func renderer(for overlay: MKOverlay) -> MKOverlayRenderer {
        if let tiles = overlay as? MKTileOverlay {
            return MKTileOverlayRenderer(tileOverlay: tiles)
        }
        if overlay is TrackOverlay {
            return TrackOverlayRenderer(overlay: overlay)
        }
        return MKOverlayRenderer(overlay: overlay)
    }
}
