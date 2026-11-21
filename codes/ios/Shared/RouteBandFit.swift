import Foundation

/// Latitude/longitude span. Foundation-only so the route-detail fit can be checked
/// without MapKit. `GeoFit.visibleRegion` uses the same numbers.
struct RouteSpan: Equatable {
    var centerLatitude: Double
    var centerLongitude: Double
    var latitudeDelta: Double
    var longitudeDelta: Double
}

/// Fits a route into the band between the title bar and the floating card.
///
/// `GeoFit.region` pads the bounding box by 1.6× and is aspect-fit to the whole
/// map, including the area under the title and under the card. Route detail uses
/// this tighter box, then `visibleRegion`, so 1× means the track fills that band.
enum RouteBandFit {
    /// Modest pad around the track. Each side is about 8% of the limiting edge.
    /// `GeoFit.region` stays at 1.6× for the other maps.
    static let contentSpanScale = 1.2
    /// Floor for a single point. Smaller than `GeoFit.region`'s 0.008°, which
    /// would leave a short route floating in the band.
    static let minimumDelta = 0.001

    static func contentSpan(
        latitudes: [Double],
        longitudes: [Double],
        padding: Double = contentSpanScale
    ) -> RouteSpan? {
        var minLat = Double.greatestFiniteMagnitude
        var maxLat = -Double.greatestFiniteMagnitude
        var minLon = Double.greatestFiniteMagnitude
        var maxLon = -Double.greatestFiniteMagnitude
        var count = 0
        for (latitude, longitude) in zip(latitudes, longitudes) {
            guard latitude.isFinite, longitude.isFinite else { continue }
            minLat = min(minLat, latitude)
            maxLat = max(maxLat, latitude)
            minLon = min(minLon, longitude)
            maxLon = max(maxLon, longitude)
            count += 1
        }
        guard count > 0 else { return nil }
        let scale = max(padding, 1)
        return RouteSpan(
            centerLatitude: (minLat + maxLat) / 2,
            centerLongitude: (minLon + maxLon) / 2,
            latitudeDelta: max(minimumDelta, (maxLat - minLat) * scale),
            longitudeDelta: max(minimumDelta, (maxLon - minLon) * scale)
        )
    }

    /// Camera region that places `content` in the vertical band not covered from
    /// the top or the bottom. Fractions are of the map view's height.
    ///
    /// MapKit aspect-fits a region to the whole view, so latitude grows until that
    /// band contains `content`, and the content center lands on the band's center.
    /// This is the body of `GeoFit.visibleRegion`.
    static func visibleRegion(
        content: RouteSpan,
        viewWidth: Double,
        viewHeight: Double,
        topFraction: Double,
        bottomFraction: Double
    ) -> RouteSpan {
        var top = max(topFraction, 0)
        var bottom = max(bottomFraction, 0)
        var obscured = top + bottom
        guard obscured > 0.02 else { return content }
        if obscured > 0.85 {
            let scale = 0.85 / obscured
            top *= scale
            bottom *= scale
            obscured = 0.85
        }
        let visible = 1 - obscured
        guard viewWidth > 1, viewHeight > 1 else {
            return latitudeShift(content, top: top, bottom: bottom, visible: visible)
        }
        let aspect = viewWidth / viewHeight
        let cosine = cos(content.centerLatitude * Double.pi / 180)
        guard cosine > 0.2 else {
            return latitudeShift(content, top: top, bottom: bottom, visible: visible)
        }
        let secant = 1 / cosine
        let latitudeForBand = content.latitudeDelta / visible
        let latitudeForWidth = content.longitudeDelta / (aspect * secant)
        let latitudeDelta = max(latitudeForBand, latitudeForWidth)
        let longitudeDelta = latitudeDelta * aspect * secant
        let centerLatitude = content.centerLatitude - latitudeDelta * (bottom - top) / 2
        return RouteSpan(
            centerLatitude: min(85, max(-85, centerLatitude)),
            centerLongitude: content.centerLongitude,
            latitudeDelta: latitudeDelta,
            longitudeDelta: longitudeDelta
        )
    }

    /// Same vertical fit when the view size is not known yet. Longitude stays put.
    private static func latitudeShift(
        _ content: RouteSpan,
        top: Double,
        bottom: Double,
        visible: Double
    ) -> RouteSpan {
        let latitudeDelta = content.latitudeDelta / visible
        return RouteSpan(
            centerLatitude: content.centerLatitude - latitudeDelta * (bottom - top) / 2,
            centerLongitude: content.centerLongitude,
            latitudeDelta: latitudeDelta,
            longitudeDelta: content.longitudeDelta
        )
    }
}

/// 1× is the band fit. A layout pass must not publish a new multiplier.
enum RouteZoomBaseline {
    static let minimum = 0.4
    static let maximum = 16.0

    /// `nil` when the region change is ours or from layout. The label then stays
    /// on the multiplier the person chose, which is 1× on the way in.
    static func publishedMultiplier(
        fittedLatitude: Double,
        displayedLatitude: Double,
        userGesture: Bool,
        programmatic: Bool
    ) -> Double? {
        guard userGesture, !programmatic else { return nil }
        let fitted = max(fittedLatitude, 0.0000001)
        let displayed = max(displayedLatitude, 0.0000001)
        return min(maximum, max(minimum, fitted / displayed))
    }
}

/// Which kilometer discs to draw. Screen y grows downward, matching UIKit.
///
/// Zoomed out, only a dyadic subset is shown (every 4th, every 8th, …) so the
/// discs do not overlap and do not cover a checkpoint name. Zooming in moves to
/// a finer step, so the set only grows, until every full kilometer is shown.
enum RouteKilometerLabels {
    /// Clear space between two disc edges, in points.
    static let discGap = 4.0
    /// Extra points around the checkpoint dot and name.
    static let checkpointPad = 4.0

    struct Disc: Equatable {
        var kilometer: Int
        var centerX: Double
        var centerY: Double
        var radius: Double
    }

    struct Obstacle: Equatable {
        var minX: Double
        var minY: Double
        var maxX: Double
        var maxY: Double
    }

    /// Matches `KilometerMarkerView`: 22 / 26 / 32 for 1 / 2 / 3 digits.
    static func discSide(for kilometer: Int) -> Double {
        let digits = String(abs(kilometer)).count
        if digits >= 3 { return 32 }
        if digits == 2 { return 26 }
        return 22
    }

    /// The disc is drawn above the track point by half its side plus 12 points.
    static func discLift(for kilometer: Int) -> Double {
        discSide(for: kilometer) / 2 + 12
    }

    static func disc(kilometer: Int, at point: (x: Double, y: Double)) -> Disc {
        let side = discSide(for: kilometer)
        return Disc(
            kilometer: kilometer,
            centerX: point.x,
            centerY: point.y - discLift(for: kilometer),
            radius: side / 2
        )
    }

    /// Label frame width. `textWidth` is the measured string; the view adds 8 points and clamps.
    static func labelWidth(textWidth: Double) -> Double {
        min(160, max(18, textWidth + 8))
    }

    /// Checkpoint marker bounds around the dot, which sits on `dotX`/`dotY`.
    /// The name extends to the right, matching `CheckpointMarkerView`.
    static func checkpointObstacle(dotX: Double, dotY: Double, labelWidth: Double, pad: Double = checkpointPad) -> Obstacle {
        let width = min(160, max(18, labelWidth))
        return Obstacle(
            minX: dotX - 5 - pad,
            minY: dotY - 8 - pad,
            maxX: dotX - 5 + 13 + width + pad,
            maxY: dotY - 8 + 16 + pad
        )
    }

    /// Kilometer numbers to show. The input is the full-kilometer list; nothing past
    /// the last of those is added. An empty input stays empty.
    static func visible(discs: [Disc], avoiding obstacles: [Obstacle], gap: Double = discGap) -> [Int] {
        let ordered = discs
            .filter { $0.kilometer >= 1 }
            .sorted { $0.kilometer < $1.kilometer }
        guard let maxKilometer = ordered.last?.kilometer else { return [] }
        var step = 1
        while step <= maxKilometer {
            let picked = ordered.filter { disc in
                disc.kilometer.isMultiple(of: step) && !hits(disc, obstacles: obstacles)
            }
            if !picked.isEmpty, separates(picked, gap: gap) {
                return picked.map(\.kilometer)
            }
            if step > maxKilometer / 2 { break }
            step *= 2
        }
        return []
    }

    /// Live workout. A disc sits on the point where its kilometer ended, with no lift.
    static func trackDisc(kilometer: Int, at point: (x: Double, y: Double)) -> Disc {
        Disc(kilometer: kilometer, centerX: point.x, centerY: point.y, radius: discSide(for: kilometer) / 2)
    }

    /// Kilometer numbers to show during a workout. The newest kilometer always shows.
    /// An older one is dropped when it would touch a newer disc that is already kept,
    /// which covers laps and out-and-back tracks as well as a zoomed-out map.
    static func newestFirst(discs: [Disc], gap: Double = discGap) -> [Int] {
        var kept: [Disc] = []
        for disc in discs.filter({ $0.kilometer >= 1 }).sorted(by: { $0.kilometer > $1.kilometer }) {
            if kept.contains(where: { $0.kilometer == disc.kilometer || overlaps($0, disc, gap: gap) }) { continue }
            kept.append(disc)
        }
        return kept.map(\.kilometer).sorted()
    }

    private static func separates(_ discs: [Disc], gap: Double) -> Bool {
        for index in discs.indices {
            for other in discs.indices where other < index {
                if overlaps(discs[index], discs[other], gap: gap) { return false }
            }
        }
        return true
    }

    private static func overlaps(_ a: Disc, _ b: Disc, gap: Double) -> Bool {
        let dx = a.centerX - b.centerX
        let dy = a.centerY - b.centerY
        let limit = a.radius + b.radius + gap
        return dx * dx + dy * dy < limit * limit
    }

    private static func hits(_ disc: Disc, obstacles: [Obstacle]) -> Bool {
        obstacles.contains { rect in
            let closestX = min(max(disc.centerX, rect.minX), rect.maxX)
            let closestY = min(max(disc.centerY, rect.minY), rect.maxY)
            let dx = disc.centerX - closestX
            let dy = disc.centerY - closestY
            return dx * dx + dy * dy < disc.radius * disc.radius
        }
    }
}
