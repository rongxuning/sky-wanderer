# Sport Type Roulette Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the training-page `TypeSheet` bottom sheet with an arc roulette overlay that scrolls along a curve, snaps to center, scales the center item, and writes `draft.sport` live.

**Architecture:** Pure geometry lives in `SportRouletteGeometry` (no SwiftUI) so `sport-roulette-check` can compile it like `StartMapChrome`. `SportRouletteOverlay` owns drag offset, snap, and tap-to-center animation; `StartMapView` toggles the overlay instead of `sheet = .type`.

**Tech Stack:** SwiftUI, Foundation/`ChromeLength` (CoreGraphics alias), existing `SportKind` / `WorkoutDraft` / `StartMapChrome` / `SkyTheme`.

## Global Constraints

- iOS training start map only (`StartMapView`); Android unchanged.
- Do not change `SportKind.allCases` order or titles.
- Keep 「设置」 as a bottom sheet; 「路线」「组队」 behavior unchanged.
- Arc horizontal midline equals left toolbar horizontal midline (`StartMapChrome.toolColumnOriginY` + half `toolColumnHeight`).
- Center item scale ≈ 1.2; selection commits when an item reaches the midline.
- Dismiss via mask tap or second tap on 「类型」; do not roll back `draft.sport`.
- New files under `codes/ios/sky-wanderer/` are auto-picked by `PBXFileSystemSynchronizedRootGroup` — do not edit `project.pbxproj` for them.
- Geometry and chrome constants must stay compilable without SwiftUI (same pattern as `StartMapChrome.swift`).

**Spec:** `docs/superpowers/specs/2026-11-27-sport-type-roulette-design.md`

---

## File map

| File | Role |
| --- | --- |
| Create: `codes/ios/sky-wanderer/SportRouletteGeometry.swift` | Arc math: item angles, positions, scale, opacity, snap index, drag→angle |
| Create: `codes/ios/sport-roulette-check/main.swift` | Unit checks for geometry (no UIKit/SwiftUI) |
| Create: `codes/ios/sky-wanderer/SportRouletteOverlay.swift` | Mask + arc items + drag/tap gestures; writes selected sport |
| Modify: `codes/ios/sky-wanderer/StartMapView.swift` | `showSportRoulette` instead of `sheet = .type`; remove `TypeSheet` usage; overlay layering |
| Modify: `codes/ios/start-map-chrome-check/main.swift` | Assert toolbar midline helper used by roulette (if added on `StartMapChrome`) |
| Optional delete: `TypeSheet` struct inside `StartMapView.swift` | Only if nothing else references it |

---

### Task 1: Arc geometry + check target

**Files:**
- Create: `codes/ios/sky-wanderer/SportRouletteGeometry.swift`
- Create: `codes/ios/sport-roulette-check/main.swift`
- Modify: `codes/ios/sky-wanderer/StartMapChrome.swift` (add `toolColumnMidY` helper)
- Modify: `codes/ios/start-map-chrome-check/main.swift` (assert mid Y)

**Interfaces:**
- Consumes: `StartMapChrome.toolColumnOriginY`, `toolColumnHeight`, `toolLeading`, `toolDiameter`
- Produces:
  - `StartMapChrome.toolColumnMidY(screenHeight:) -> ChromeLength`
  - `enum SportRouletteGeometry` with:
    - `static let itemCountHintVisible = 5`
    - `static let radius: ChromeLength`
    - `static let angleStep: ChromeLength` (radians between neighbors)
    - `static let centerScale: ChromeLength = 1.2`
    - `static let edgeScale: ChromeLength = 1.0`
    - `static let edgeOpacity: ChromeLength = 0.45`
    - `static let dotDiameter: ChromeLength`
    - `static let gapAfterTools: ChromeLength` (leading gap from tool column to dots)
    - `static func centerY(screenHeight:) -> ChromeLength` → same as tool column mid Y
    - `static func centerX(screenWidth unused / leading layout:) -> ChromeLength` → x of arc center (left of screen)
    - `static func angle(forIndex index: Int, scrollOffset: ChromeLength) -> ChromeLength` — item angle relative to midline (`0` = on midline); `scrollOffset` is in “index units” (0 = first sport centered)
    - `static func position(index: Int, scrollOffset: ChromeLength, screenHeight: ChromeLength) -> (x: ChromeLength, y: ChromeLength)`
    - `static func scale(forAngle angle: ChromeLength) -> ChromeLength`
    - `static func opacity(forAngle angle: ChromeLength) -> ChromeLength`
    - `static func nearestIndex(scrollOffset: ChromeLength, itemCount: Int) -> Int`
    - `static func clampedScrollOffset(_ offset: ChromeLength, itemCount: Int) -> ChromeLength`
    - `static func scrollOffset(centering index: Int) -> ChromeLength`

**Geometry convention (lock this in code comments):**
- Midline item sits at angle `0` on a circle whose center is to the **left** of the screen so the visible arc bows right `)`.
- `θ = (index - scrollOffset) * angleStep`
- `x = arcCenterX + radius * cos(θ)` with `arcCenterX` negative or small so dots sit just right of the tool column
- `y = centerY + radius * sin(θ)`
- Choose `radius` and `angleStep` so ~5 items fit the vertical band around the toolbar (tune so vertical span of ±2 steps ≈ toolbar height ± a bit). Starting values to implement then adjust only if checks/layout fail: `radius = 220`, `angleStep = 0.22` rad (~12.6°), `gapAfterTools = 12`, `dotDiameter = 44`.

- [ ] **Step 1: Add toolbar mid-Y helper**

In `StartMapChrome.swift`, after `toolColumnOriginY`:

```swift
/// Horizontal midline of the left tool column (same Y the roulette arc uses).
static func toolColumnMidY(screenHeight: ChromeLength) -> ChromeLength {
    toolColumnOriginY(screenHeight: screenHeight) + toolColumnHeight / 2
}
```

- [ ] **Step 2: Extend start-map-chrome-check**

Append:

```swift
near(
    StartMapChrome.toolColumnMidY(screenHeight: 852),
    326 + 100,
    "tool column midline is origin + half of 200pt height"
)
```

Run:

```bash
cd /path/to/sky-wanderer
swiftc -swift-version 5 codes/ios/sky-wanderer/StartMapChrome.swift \
  codes/ios/start-map-chrome-check/main.swift \
  -o /tmp/start-map-chrome-check && /tmp/start-map-chrome-check
```

Expected: `start-map-chrome-check: ok`

- [ ] **Step 3: Write failing sport-roulette-check**

Create `codes/ios/sport-roulette-check/main.swift`:

```swift
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

let screen: ChromeLength = 852
let itemCount = 8

near(
    SportRouletteGeometry.centerY(screenHeight: screen),
    StartMapChrome.toolColumnMidY(screenHeight: screen),
    "roulette midline matches tool column midline"
)

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

let mid = SportRouletteGeometry.position(index: 2, scrollOffset: 2, screenHeight: screen)
near(mid.y, SportRouletteGeometry.centerY(screenHeight: screen), "centered item sits on midline Y")

let above = SportRouletteGeometry.position(index: 1, scrollOffset: 2, screenHeight: screen)
let below = SportRouletteGeometry.position(index: 3, scrollOffset: 2, screenHeight: screen)
check(above.y < mid.y, "lower index is above midline")
check(below.y > mid.y, "higher index is below midline")
check(above.x < mid.x || abs(Double(above.x - mid.x)) < 1, "arc bows so off-center x is not right of center")
check(below.x < mid.x || abs(Double(below.x - mid.x)) < 1, "lower arc side also left of or at center x")

let leadingDot = StartMapChrome.toolLeading + StartMapChrome.toolDiameter + SportRouletteGeometry.gapAfterTools
near(mid.x, leadingDot + SportRouletteGeometry.dotDiameter / 2, "centered dot sits just right of the tool column")

if failures.isEmpty {
    print("sport-roulette-check: ok")
} else {
    for failure in failures { print("FAIL \(failure)") }
    exit(1)
}
```

- [ ] **Step 4: Run check — expect compile failure**

```bash
swiftc -swift-version 5 \
  codes/ios/sky-wanderer/StartMapChrome.swift \
  codes/ios/sky-wanderer/SportRouletteGeometry.swift \
  codes/ios/sport-roulette-check/main.swift \
  -o /tmp/sport-roulette-check && /tmp/sport-roulette-check
```

Expected: error that `SportRouletteGeometry.swift` is missing / type not found.

- [ ] **Step 5: Implement `SportRouletteGeometry.swift`**

Create `codes/ios/sky-wanderer/SportRouletteGeometry.swift` with Foundation + optional CoreGraphics (same `#if canImport(CoreGraphics)` / `ChromeLength` pattern as `StartMapChrome`), implementing every symbol the check imports. Use:

```swift
static func angle(forIndex index: Int, scrollOffset: ChromeLength) -> ChromeLength {
    ChromeLength(index) * angleStep - scrollOffset * angleStep
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
    let rounded = Int((Double(scrollOffset)).rounded())
    return max(0, min(itemCount - 1, rounded))
}

static func scrollOffset(centering index: Int) -> ChromeLength {
    ChromeLength(index)
}

static func clampedScrollOffset(_ offset: ChromeLength, itemCount: Int) -> ChromeLength {
    max(0, min(ChromeLength(itemCount - 1), offset))
}
```

`position` / `centerX`: place arc center so that at `θ = 0`, dot center x equals `toolLeading + toolDiameter + gapAfterTools + dotDiameter/2`. Solve `arcCenterX = thatX - radius` (since `cos(0) = 1` if using `x = arcCenterX + radius * cos(θ)` with θ measured from +x; if that puts the bow the wrong way, use `x = arcCenterX + radius * cos(θ)` with θ from the positive x-axis and ensure neighbors have `cos(θ) < 1` so x decreases — that yields the `)` bow).

- [ ] **Step 6: Run check — expect pass**

Same `swiftc` command as Step 4. Expected: `sport-roulette-check: ok`

- [ ] **Step 7: Commit**

```bash
git add codes/ios/sky-wanderer/SportRouletteGeometry.swift \
  codes/ios/sky-wanderer/StartMapChrome.swift \
  codes/ios/sport-roulette-check/main.swift \
  codes/ios/start-map-chrome-check/main.swift
git commit -m "feat(ios): add sport roulette arc geometry and checks"
```

---

### Task 2: Roulette overlay UI

**Files:**
- Create: `codes/ios/sky-wanderer/SportRouletteOverlay.swift`

**Interfaces:**
- Consumes: `SportRouletteGeometry.*`, `SportKind.allCases`, `SkyTheme`, `StartMapChrome`
- Produces:
  - `struct SportRouletteOverlay: View` with
    - `var sports: [SportKind] = Array(SportKind.allCases)`
    - `@Binding var selection: SportKind`
    - `var screenHeight: CGFloat`
    - `var onDismiss: () -> Void`
  - Internal `@State private var scrollOffset: CGFloat` (index units)
  - Internal `@State private var dragStartOffset: CGFloat?`
  - On appear: `scrollOffset = SportRouletteGeometry.scrollOffset(centering: index of selection)`
  - On snap / tap settle: `selection = sports[nearest]`

- [ ] **Step 1: Create overlay shell**

`SportRouletteOverlay.swift`:

```swift
import SwiftUI

struct SportRouletteOverlay: View {
    var sports: [SportKind] = Array(SportKind.allCases)
    @Binding var selection: SportKind
    var screenHeight: CGFloat
    var onDismiss: () -> Void

    @State private var scrollOffset: CGFloat = 0
    @State private var dragOrigin: CGFloat?

    private var itemCount: Int { sports.count }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            ForEach(Array(sports.enumerated()), id: \.element.id) { index, sport in
                item(sport: sport, index: index)
            }
        }
        .onAppear {
            if let idx = sports.firstIndex(of: selection) {
                scrollOffset = CGFloat(SportRouletteGeometry.scrollOffset(centering: idx))
            }
        }
        .gesture(drag)
    }

    // item / drag / commit helpers — Step 2–3
}
```

Mask taps must not steal taps from items: put item buttons above the mask in z-order (ForEach after mask) and use `.highPriorityGesture` only on the arc band if needed. Prefer: mask `onTapGesture` + each item `Button` with enough hit area.

- [ ] **Step 2: Place items on the arc**

```swift
@ViewBuilder
private func item(sport: SportKind, index: Int) -> some View {
    let angle = SportRouletteGeometry.angle(forIndex: index, scrollOffset: ChromeLength(scrollOffset))
    let point = SportRouletteGeometry.position(
        index: index,
        scrollOffset: ChromeLength(scrollOffset),
        screenHeight: ChromeLength(screenHeight)
    )
    let scale = CGFloat(SportRouletteGeometry.scale(forAngle: angle))
    let opacity = CGFloat(SportRouletteGeometry.opacity(forAngle: angle))
    let dot = CGFloat(SportRouletteGeometry.dotDiameter)

    Button {
        tap(index)
    } label: {
        HStack(spacing: SkyTheme.Spacing.related) {
            Image(systemName: sport.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(SkyTheme.Color.onStarryGray)
                .frame(width: dot, height: dot)
                .background(SkyTheme.Color.starryGray, in: Circle())
            Text(sport.title)
                .font(.system(size: 16, weight: abs(Double(angle)) < 0.001 ? .semibold : .regular))
                .foregroundStyle(SkyTheme.Color.ink)
        }
        .scaleEffect(scale, anchor: .leading)
        .opacity(opacity)
    }
    .buttonStyle(.plain)
    .position(x: CGFloat(point.x) + labelBiasX, y: CGFloat(point.y))
}

/// Nudge so `position` anchors the HStack; keep the **dot center** on the arc.
private var labelBiasX: CGFloat {
    // Approximate: half of (dot + spacing + typical label width) is wrong for variable labels.
    // Prefer aligning with an HStack where the dot is leading and position uses:
    // x = point.x + (dot/2) is already the dot center from geometry — layout the label
    // with padding/offset so the circle center stays at point.
    0
}
```

**Layout note for implementer:** Prefer a ZStack per item: `Circle` centered at `point`, `Text` offset to the right of the circle (`point.x + dot/2 + gap`). Do not let `HStack.position` drift the dot off the arc.

- [ ] **Step 3: Drag + snap + tap-to-center**

```swift
private var drag: some Gesture {
    DragGesture(minimumDistance: 2)
        .onChanged { value in
            if dragOrigin == nil { dragOrigin = scrollOffset }
            let origin = dragOrigin ?? scrollOffset
            // Vertical drag: finger up → decrease index offset (previous sports toward center)
            let deltaIndex = -value.translation.height / CGFloat(SportRouletteGeometry.dragPixelsPerStep)
            scrollOffset = CGFloat(
                SportRouletteGeometry.clampedScrollOffset(
                    ChromeLength(origin + deltaIndex),
                    itemCount: itemCount
                )
            )
        }
        .onEnded { value in
            dragOrigin = nil
            let predicted = scrollOffset - value.predictedEndTranslation.height
                / CGFloat(SportRouletteGeometry.dragPixelsPerStep)
            let nearest = SportRouletteGeometry.nearestIndex(
                scrollOffset: ChromeLength(predicted),
                itemCount: itemCount
            )
            withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                scrollOffset = CGFloat(SportRouletteGeometry.scrollOffset(centering: nearest))
            }
            commit(nearest)
        }
}

private func tap(_ index: Int) {
    withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
        scrollOffset = CGFloat(SportRouletteGeometry.scrollOffset(centering: index))
    }
    commit(index)
}

private func commit(_ index: Int) {
    guard sports.indices.contains(index) else { return }
    selection = sports[index]
}
```

Add to geometry:

```swift
static let dragPixelsPerStep: ChromeLength = 44
```

Extend `sport-roulette-check` with `near(SportRouletteGeometry.dragPixelsPerStep, 44, "...")` and re-run the check.

- [ ] **Step 4: Commit**

```bash
git add codes/ios/sky-wanderer/SportRouletteOverlay.swift \
  codes/ios/sky-wanderer/SportRouletteGeometry.swift \
  codes/ios/sport-roulette-check/main.swift
git commit -m "feat(ios): add sport roulette overlay with arc drag and snap"
```

---

### Task 3: Wire `StartMapView` and remove type sheet

**Files:**
- Modify: `codes/ios/sky-wanderer/StartMapView.swift`

**Interfaces:**
- Consumes: `SportRouletteOverlay`
- Produces: `showSportRoulette: Bool`; 「类型」 toggles overlay; other tools dismiss overlay first

- [ ] **Step 1: Replace type sheet state**

Changes in `StartMapView`:

1. Change `StartSheet` to settings-only:

```swift
enum StartSheet: String, Identifiable {
    case settings
    var id: String { rawValue }
}
```

2. Add `@State private var showSportRoulette = false`

3. In the `GeometryReader` `ZStack` (or as an overlay above the map, **below** `toolColumn` / `startButton` so chrome stays tappable), when `showSportRoulette`:

```swift
.overlay {
    if showSportRoulette {
        SportRouletteOverlay(
            selection: $draft.sport,
            screenHeight: geo.size.height,
            onDismiss: { showSportRoulette = false }
        )
        .transition(.opacity)
    }
}
```

Place this overlay **before** the tool-column / start-button overlays in the modifier chain (or give tools a higher zIndex) so 「类型」 remains hittable to close.

4. `performTool`:

```swift
private func performTool(_ label: String) {
    switch label {
    case "类型":
        showSportRoulette.toggle()
    case "路线":
        showSportRoulette = false
        cancelCountdown()
        pickingRoute = true
    case "组队":
        showSportRoulette = false
        cancelCountdown()
        path.append(TrainRoute.team)
    case "设置":
        showSportRoulette = false
        sheet = .settings
    default:
        break
    }
}
```

5. Sheet switch — remove `.type` case:

```swift
.sheet(item: $sheet) { item in
    switch item {
    case .settings: StartSettingsSheet().presentationDetents([.medium])
    }
}
```

6. Delete `struct TypeSheet` entirely from this file (grep repo for `TypeSheet` first; if only here, delete).

- [ ] **Step 2: Grep cleanup**

```bash
rg -n "TypeSheet|StartSheet\\.type|showSportRoulette|case type" codes/ios
```

Expected: no `TypeSheet`; `case type` gone from `StartSheet`; roulette wiring present.

- [ ] **Step 3: Re-run geometry checks**

```bash
swiftc -swift-version 5 codes/ios/sky-wanderer/StartMapChrome.swift \
  codes/ios/start-map-chrome-check/main.swift \
  -o /tmp/start-map-chrome-check && /tmp/start-map-chrome-check

swiftc -swift-version 5 \
  codes/ios/sky-wanderer/StartMapChrome.swift \
  codes/ios/sky-wanderer/SportRouletteGeometry.swift \
  codes/ios/sport-roulette-check/main.swift \
  -o /tmp/sport-roulette-check && /tmp/sport-roulette-check
```

Expected: both print `ok`.

- [ ] **Step 4: Commit**

```bash
git add codes/ios/sky-wanderer/StartMapView.swift
git commit -m "feat(ios): open sport type roulette instead of type sheet"
```

---

### Task 4: Manual verification checklist (device / simulator)

No automated UI test in-repo for SwiftUI map chrome. Verify on simulator or device against the spec test points:

- [ ] **Step 1: Run through checklist**

1. Tap 「类型」 → mask + arc appear; no bottom sheet.
2. Current `draft.sport` is on the midline and visibly larger (~1.2).
3. Drag scrolls along the arc; release snaps; toolbar icon updates immediately.
4. Tap a non-center row → smooth spring to center; selection updates.
5. Tap mask or 「类型」 again → closes; sport stays as last center item.
6. 「设置」 still presents a sheet; 「路线」「组队」 still work; roulette closes first.
7. Visually confirm arc midline aligns with toolbar midline.

- [ ] **Step 2: Commit any tuning** (radius / angleStep / colors) if needed after verification

```bash
git add codes/ios/sky-wanderer/SportRouletteGeometry.swift \
  codes/ios/sky-wanderer/SportRouletteOverlay.swift
git commit -m "fix(ios): tune sport roulette arc layout to match reference"
```

If no tuning needed, skip this commit.

---

## Spec coverage self-check

| Spec requirement | Task |
| --- | --- |
| No bottom type sheet | Task 3 |
| Mask + arc roulette | Task 2–3 |
| Scroll along arc | Task 1–2 |
| Icon in dot + name | Task 2 |
| Midline = toolbar midline | Task 1 (`centerY` / `toolColumnMidY`) |
| Live commit on center | Task 2 `commit` |
| Tap non-center → spring to center | Task 2 `tap` |
| Scale ~1.2 continuous with angle | Task 1 `scale(forAngle:)` |
| Dismiss mask / type toggle | Task 2–3 |
| Settings sheet kept | Task 3 |
| iOS only | Global constraints |
| Geometry unit-tested | Task 1 `sport-roulette-check` |
