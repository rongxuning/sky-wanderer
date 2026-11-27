import Foundation

/// Semicircle layout for the sport-type roulette on the start map.
/// Uses `ChromeLength` from `StartMapChrome.swift` (same `#if canImport(CoreGraphics)` pattern).
///
/// Convention: the selected (midline) item sits at the **screen center**. The arc
/// center is to its left so the visible span is a right-facing semicircle `)`.
/// - `θ = (index - scrollOffset) * angleStep`
/// - Five visible steps span `π` (`angleStep = π/4`)
/// - `x = arcCenterX + radius * cos(θ)` with `arcCenterX = screenCenterX - radius`
/// - `y = screenCenterY + radius * sin(θ)`
enum SportRouletteGeometry {
    static let itemCountHintVisible = 5
    /// Semicircle radius; selected item sits `radius` to the right of the arc center.
    static let radius: ChromeLength = 180
    /// Four steps between five visible items cover a semicircle.
    static let angleStep: ChromeLength = .pi / 4
    /// Unwrapped angle past which items are not drawn. Keeps far items from wrapping onto the visible arc.
    static let hiddenBeyondAngle: ChromeLength = angleStep * 2.5
    static let centerScale: ChromeLength = 1.2
    static let edgeScale: ChromeLength = 1.0
    static let edgeOpacity: ChromeLength = 0.45
    static let dotDiameter: ChromeLength = 44
    /// Larger than the old shallow-arc step so a finger flick still feels measured.
    static let dragPixelsPerStep: ChromeLength = 64

    /// Vertical center of the selected item — screen midline.
    static func centerY(screenHeight: ChromeLength) -> ChromeLength {
        screenHeight / 2
    }

    /// Horizontal center of the selected item — screen midline.
    static func selectedCenterX(screenWidth: ChromeLength) -> ChromeLength {
        screenWidth / 2
    }

    /// X of the arc center (left of the selected item).
    static func centerX(screenWidth: ChromeLength) -> ChromeLength {
        selectedCenterX(screenWidth: screenWidth) - radius
    }

    /// Item angle relative to the midline (`0` = on midline). `scrollOffset` is in index units.
    static func angle(forIndex index: Int, scrollOffset: ChromeLength) -> ChromeLength {
        ChromeLength(index) * angleStep - scrollOffset * angleStep
    }

    static func position(
        index: Int,
        scrollOffset: ChromeLength,
        screenWidth: ChromeLength,
        screenHeight: ChromeLength
    ) -> (x: ChromeLength, y: ChromeLength) {
        let theta = angle(forIndex: index, scrollOffset: scrollOffset)
        let cx = centerX(screenWidth: screenWidth)
        let cy = centerY(screenHeight: screenHeight)
        let x = cx + radius * ChromeLength(cos(Double(theta)))
        let y = cy + radius * ChromeLength(sin(Double(theta)))
        return (x, y)
    }

    static func scale(forAngle angle: ChromeLength) -> ChromeLength {
        let t = min(1, abs(Double(angle)) / Double(angleStep * 2))
        return centerScale - ChromeLength(t) * (centerScale - edgeScale)
    }

    static func opacity(forAngle angle: ChromeLength) -> ChromeLength {
        let a = abs(Double(angle))
        let t = min(1, a / Double(angleStep * 2))
        let base = 1 - ChromeLength(t) * (1 - edgeOpacity)
        let fadeSpan = Double(hiddenBeyondAngle - angleStep * 2)
        let fade = max(0, min(1, (Double(hiddenBeyondAngle) - a) / fadeSpan))
        return base * ChromeLength(fade)
    }

    static func isRendered(angle: ChromeLength) -> Bool {
        abs(Double(angle)) <= Double(hiddenBeyondAngle)
    }

    static func nearestIndex(scrollOffset: ChromeLength, itemCount: Int) -> Int {
        let rounded = Int(Double(scrollOffset).rounded())
        return max(0, min(itemCount - 1, rounded))
    }

    static func scrollOffset(centering index: Int) -> ChromeLength {
        ChromeLength(index)
    }

    static func clampedScrollOffset(_ offset: ChromeLength, itemCount: Int) -> ChromeLength {
        max(0, min(ChromeLength(itemCount - 1), offset))
    }

    /// Release projection from the drag gesture's origin offset (not live `scrollOffset`, which already includes translation).
    /// Zero predicted flick (`predictedEndTranslation == 0`) leaves the offset at `dragOrigin`.
    static func projectedScrollOffsetOnRelease(
        dragOrigin: ChromeLength,
        predictedEndTranslationHeight: ChromeLength,
        itemCount: Int
    ) -> ChromeLength {
        let projected = dragOrigin - predictedEndTranslationHeight / dragPixelsPerStep
        return clampedScrollOffset(projected, itemCount: itemCount)
    }

    /// True when the item sits on the selection midline (angle ≈ 0).
    static func isOnMidline(angle: ChromeLength) -> Bool {
        abs(Double(angle)) < 0.001
    }
}
