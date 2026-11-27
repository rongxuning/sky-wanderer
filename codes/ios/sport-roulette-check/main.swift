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
near(SportRouletteGeometry.angleStep, .pi / 4, "five visible items span a semicircle")
near(SportRouletteGeometry.dragPixelsPerStep, 64, "drag pixels per index step")
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
check(above.x < mid.x || abs(Double(above.x - mid.x)) < 1, "semicircle bows so off-center x is not right of center")
check(below.x < mid.x || abs(Double(below.x - mid.x)) < 1, "lower semicircle side also left of or at center x")

// Neighbors at ±angleStep sit near ±45° on the semicircle.
let expectedNeighborX = SportRouletteGeometry.centerX(screenWidth: screenWidth)
    + SportRouletteGeometry.radius * ChromeLength(cos(Double(SportRouletteGeometry.angleStep)))
near(above.x, expectedNeighborX, "upper neighbor follows semicircle x")
near(below.x, expectedNeighborX, "lower neighbor follows semicircle x")

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
