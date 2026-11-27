import Foundation

/// Arc layout for the sport-type roulette beside the start-map tool column.
/// Uses `ChromeLength` from `StartMapChrome.swift` (same `#if canImport(CoreGraphics)` pattern).
///
/// Convention: the midline item sits at angle `0` on a circle whose center is to the
/// **left** of the screen so the visible arc bows right `)`.
/// - `θ = (index - scrollOffset) * angleStep`
/// - `x = arcCenterX + radius * cos(θ)` with `arcCenterX` left of the dots
/// - `y = centerY + radius * sin(θ)`
enum SportRouletteGeometry {
    static let itemCountHintVisible = 5
    static let radius: ChromeLength = 220
    static let angleStep: ChromeLength = 0.22
    static let centerScale: ChromeLength = 1.2
    static let edgeScale: ChromeLength = 1.0
    static let edgeOpacity: ChromeLength = 0.45
    static let dotDiameter: ChromeLength = 44
    static let dragPixelsPerStep: ChromeLength = 44
    static let gapAfterTools: ChromeLength = 12

    static func centerY(screenHeight: ChromeLength) -> ChromeLength {
        StartMapChrome.toolColumnMidY(screenHeight: screenHeight)
    }

    /// X of the arc center (left of the screen). `screenWidth` is unused; layout follows the tool column.
    static func centerX(screenWidth: ChromeLength = 0) -> ChromeLength {
        _ = screenWidth
        let dotCenterXOnMidline =
            StartMapChrome.toolLeading + StartMapChrome.toolDiameter + gapAfterTools + dotDiameter / 2
        return dotCenterXOnMidline - radius
    }

    /// Item angle relative to the midline (`0` = on midline). `scrollOffset` is in index units.
    static func angle(forIndex index: Int, scrollOffset: ChromeLength) -> ChromeLength {
        ChromeLength(index) * angleStep - scrollOffset * angleStep
    }

    static func position(
        index: Int,
        scrollOffset: ChromeLength,
        screenHeight: ChromeLength
    ) -> (x: ChromeLength, y: ChromeLength) {
        let theta = angle(forIndex: index, scrollOffset: scrollOffset)
        let cx = centerX()
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
        let t = min(1, abs(Double(angle)) / Double(angleStep * 2))
        return 1 - ChromeLength(t) * (1 - edgeOpacity)
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
}