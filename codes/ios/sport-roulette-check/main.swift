import Foundation

// swiftc -swift-version 5 \
//   codes/ios/sky-wanderer/StartMapChrome.swift \
//   codes/ios/sky-wanderer/SportRouletteGeometry.swift \
//   codes/ios/sport-roulette-check/main.swift \
//   -o /tmp/sport-roulette-check && /tmp/sport-roulette-check

var failures: [String] = []

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { failures.append(message) }
}

func near(_ actual: ChromeLength, _ expected: ChromeLength, _ message: String) {
    let delta = abs(Double(actual) - Double(expected))
    check(delta < 0.02, "\(message): \(actual) !~ \(expected)")
}

let screenWidth: ChromeLength = 393
let screenHeight: ChromeLength = 852
let itemCount = 8

near(
    SportRouletteGeometry.centerY(screenHeight: screenHeight),
    screenHeight / 2,
    "roulette midline Y is screen vertical center"
)
near(
    SportRouletteGeometry.selectedCenterX(screenWidth: screenWidth),
    screenWidth / 2,
    "selected item X is screen horizontal center"
)
near(
    SportRouletteGeometry.centerX(screenWidth: screenWidth),
    screenWidth / 2 - SportRouletteGeometry.radius,
    "arc center sits radius left of screen center"
)
near(SportRouletteGeometry.dotDiameter, 44, "circular icon diameter")
near(SportRouletteGeometry.neighborEdgeGap, 22, "neighbor edge gap is half a circular icon")
near(
    SportRouletteGeometry.neighborCenterDistance,
    SportRouletteGeometry.dotDiameter + SportRouletteGeometry.neighborEdgeGap,
    "center distance = diameter + half-diameter gap"
)
let semicircleRadius = SportRouletteGeometry.neighborCenterDistance
    / (2 * ChromeLength(sin(Double(.pi / 4) / 2)))
near(
    SportRouletteGeometry.radius,
    semicircleRadius * 1.2,
    "radius is 20% larger than five-on-semicircle"
)
near(
    SportRouletteGeometry.angleStep,
    2 * ChromeLength(asin(Double(
        SportRouletteGeometry.neighborCenterDistance / (2 * SportRouletteGeometry.radius)
    ))),
    "angleStep follows chord and enlarged radius"
)
check(
    Double(SportRouletteGeometry.angleStep) * 4 < Double.pi,
    "five visible items span less than a semicircle"
)
check(
    Double(SportRouletteGeometry.angleStep) < Double.pi / 4,
    "enlarged radius tightens angleStep below π/4"
)
near(SportRouletteGeometry.dragPixelsPerStep, 77, "drag pixels per index step (20% slower than 64)")
near(SportRouletteGeometry.snapSpringResponse, 0.456, "snap spring is 20% slower than 0.38")
near(SportRouletteGeometry.centerScale, 1.2, "center scale is 1.2")
near(SportRouletteGeometry.scale(forAngle: 0), 1.2, "angle 0 is fully scaled")
check(
    SportRouletteGeometry.scale(forAngle: SportRouletteGeometry.angleStep) < 1.2,
    "neighbor angle is smaller than center"
)
check(
    SportRouletteGeometry.opacity(forAngle: 0) > SportRouletteGeometry.opacity(forAngle: SportRouletteGeometry.angleStep * 2),
    "center is more opaque than far items"
)
check(
    SportRouletteGeometry.opacity(forAngle: SportRouletteGeometry.angleStep * 2) > 0,
    "items at the semicircle edge stay visible"
)
check(
    SportRouletteGeometry.opacity(forAngle: SportRouletteGeometry.hiddenBeyondAngle) == 0,
    "items past the hidden angle fade to zero"
)
check(
    SportRouletteGeometry.isRendered(angle: SportRouletteGeometry.angleStep * 2),
    "edge item is rendered"
)
check(
    !SportRouletteGeometry.isRendered(angle: SportRouletteGeometry.angleStep * 7),
    "far item does not wrap onto the arc"
)
check(
    !SportRouletteGeometry.isRendered(angle: -SportRouletteGeometry.angleStep * 7),
    "far item on the other side does not wrap onto the arc"
)
check(SportRouletteGeometry.isOnMidline(angle: 0), "angle 0 is on midline")
check(!SportRouletteGeometry.isOnMidline(angle: SportRouletteGeometry.angleStep), "neighbor is off midline")

near(SportRouletteGeometry.scrollOffset(centering: 0), 0, "first item centers at offset 0")
near(SportRouletteGeometry.scrollOffset(centering: 3), 3, "index 3 centers at offset 3")

check(
    SportRouletteGeometry.nearestIndex(scrollOffset: 2.4, itemCount: itemCount) == 2,
    "2.4 snaps toward 2"
)
check(
    SportRouletteGeometry.nearestIndex(scrollOffset: 2.6, itemCount: itemCount) == 3,
    "2.6 snaps toward 3"
)
check(
    SportRouletteGeometry.nearestIndex(scrollOffset: -1, itemCount: itemCount) == 0,
    "below 0 clamps to 0"
)
check(
    SportRouletteGeometry.nearestIndex(scrollOffset: 99, itemCount: itemCount) == itemCount - 1,
    "above max clamps to last"
)

let mid = SportRouletteGeometry.position(
    index: 2,
    scrollOffset: 2,
    screenWidth: screenWidth,
    screenHeight: screenHeight
)
near(mid.x, screenWidth / 2, "centered item sits on screen horizontal center")
near(mid.y, screenHeight / 2, "centered item sits on screen vertical center")

let above = SportRouletteGeometry.position(
    index: 1,
    scrollOffset: 2,
    screenWidth: screenWidth,
    screenHeight: screenHeight
)
let below = SportRouletteGeometry.position(
    index: 3,
    scrollOffset: 2,
    screenWidth: screenWidth,
    screenHeight: screenHeight
)
check(above.y < mid.y, "lower index is above midline")
check(below.y > mid.y, "higher index is below midline")
check(above.x < mid.x || abs(Double(above.x - mid.x)) < 1, "arc bows so off-center x is not right of center")
check(below.x < mid.x || abs(Double(below.x - mid.x)) < 1, "lower arc side also left of or at center x")
let neighborChord = ChromeLength(
    (Double(above.x - mid.x) * Double(above.x - mid.x) + Double(above.y - mid.y) * Double(above.y - mid.y)).squareRoot()
)
near(neighborChord, SportRouletteGeometry.neighborCenterDistance, "on-screen neighbor chord matches geometry")

let expectedNeighborX = SportRouletteGeometry.centerX(screenWidth: screenWidth)
    + SportRouletteGeometry.radius * ChromeLength(cos(Double(SportRouletteGeometry.angleStep)))
near(above.x, expectedNeighborX, "upper neighbor follows arc x")
near(below.x, expectedNeighborX, "lower neighbor follows arc x")

near(
    SportRouletteGeometry.projectedScrollOffsetOnRelease(
        dragOrigin: 2.5,
        predictedEndTranslationHeight: 0,
        itemCount: itemCount
    ),
    2.5,
    "zero-velocity release projection equals drag origin"
)

if failures.isEmpty {
    print("sport-roulette-check: ok")
} else {
    for failure in failures { print("FAIL \(failure)") }
    exit(1)
}
