import Foundation

// swiftc -swift-version 5 codes/ios/sky-wanderer/StartMapChrome.swift \
//   codes/ios/start-map-chrome-check/main.swift \
//   -o /tmp/start-map-chrome-check && /tmp/start-map-chrome-check

var failures: [String] = []

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures.append(message)
    }
}

func near(_ actual: ChromeLength, _ expected: ChromeLength, _ message: String) {
    let delta = abs(Double(actual) - Double(expected))
    check(delta < 0.001, "\(message): \(actual) !~ \(expected)")
}

// MARK: - Left column, centered on the full screen

near(StartMapChrome.toolColumnHeight, 200, "four 44pt buttons and three 8pt gaps are 200pt")
near(StartMapChrome.toolColumnOriginY(screenHeight: 852), 326, "column top on an 852pt phone")
near(
    StartMapChrome.toolColumnOriginY(screenHeight: 852) + StartMapChrome.toolColumnHeight,
    526,
    "column bottom on an 852pt phone"
)
near(
    StartMapChrome.toolColumnMidY(screenHeight: 852),
    326 + 100,
    "tool column midline is origin + half of 200pt height"
)
near(StartMapChrome.toolLeading, 16, "column sits 16pt from the leading edge")
near(StartMapChrome.toolDiameter, 44, "each map button is a 44pt target")
near(StartMapChrome.toolGap, 8, "buttons are 8pt apart")
check(StartMapChrome.toolCount == 4, "one vertical column of four buttons")

check(
    StartMapChrome.tools.map(\.label) == ["类型", "路线", "组队", "设置"],
    "top to bottom: 类型, 路线, 组队, 设置"
)
check(
    StartMapChrome.tools.map(\.symbol) == [
        "figure.run",
        "point.topleft.down.to.point.bottomright.curvepath",
        "person.2",
        "gearshape",
    ],
    "symbols are run, path, two people, gear"
)
check(StartMapChrome.typeTool.label == "类型", "type tool is the first column item")
check(
    StartMapChrome.companionTools.map(\.label) == ["路线", "组队", "设置"],
    "companions are the three tools under 类型"
)

let home = StartMapChrome.typeToolHomeCenter(screenHeight: 852)
near(home.x, 16 + 22, "type tool home x is column center")
near(home.y, 326 + 22, "type tool home y is top button center")
let screenCenter = StartMapChrome.typeToolScreenCenter(screenWidth: 393, screenHeight: 852)
near(screenCenter.x, 196.5, "type tool screen center x")
near(screenCenter.y, 426, "type tool screen center y")
let midFlight = StartMapChrome.typeToolPosition(progress: 0.5, screenWidth: 393, screenHeight: 852)
near(midFlight.x, (home.x + screenCenter.x) / 2, "mid-flight x lerps home to center")
near(midFlight.y, (home.y + screenCenter.y) / 2, "mid-flight y lerps home to center")
let docked = StartMapChrome.typeToolPosition(progress: 0, screenWidth: 393, screenHeight: 852)
near(docked.x, home.x, "progress 0 stays at home x")
near(docked.y, home.y, "progress 0 stays at home y")
let arrived = StartMapChrome.typeToolPosition(progress: 1, screenWidth: 393, screenHeight: 852)
near(arrived.x, screenCenter.x, "progress 1 reaches screen center x")
near(arrived.y, screenCenter.y, "progress 1 reaches screen center y")

// Records filter: top edge on the screen horizontal midline.
let filterHome = StartMapChrome.filterToolHomeCenter(screenHeight: 852)
near(filterHome.x, 16 + 22, "filter tool home x matches the left column")
near(filterHome.y, 426 + 22, "filter tool top sits on the screen midline")
near(
    filterHome.y - StartMapChrome.toolDiameter / 2,
    426,
    "filter tool top edge is screenHeight / 2"
)
let filterDocked = StartMapChrome.filterToolPosition(progress: 0, screenWidth: 393, screenHeight: 852)
near(filterDocked.x, filterHome.x, "filter progress 0 stays at home x")
near(filterDocked.y, filterHome.y, "filter progress 0 stays at home y")
let filterArrived = StartMapChrome.filterToolPosition(progress: 1, screenWidth: 393, screenHeight: 852)
near(filterArrived.x, screenCenter.x, "filter progress 1 reaches screen center x")
near(filterArrived.y, screenCenter.y, "filter progress 1 reaches screen center y")

// Route search: docked above import; searching rides 12pt above the keyboard.
near(StartMapChrome.searchAboveKeyboardGap, 12, "search field clears the keyboard by 12pt")
near(
    StartMapChrome.routeSearchChromeTop(searchExpanded: false, screenHeight: 852, keyboardTop: nil),
    852 / 2 - 8 - 44,
    "docked search top sits one gap above the screen midline"
)
near(
    StartMapChrome.routeSearchChromeTop(searchExpanded: true, screenHeight: 852, keyboardTop: 516),
    516 - 12 - 44,
    "searching top puts the field bottom 12pt above the keyboard top"
)
near(
    StartMapChrome.routeSearchChromeTop(searchExpanded: true, screenHeight: 852, keyboardTop: nil),
    852 - 12 - 44,
    "without a keyboard frame, searching rests 12pt above the view bottom"
)

// MARK: - Start button 16pt above the measured pill

near(StartMapChrome.startDiameter, 72, "Start is a 72pt circle")
near(StartMapChrome.gapAboveTabBar, 16, "the gap above the pill is 16pt")
check(StartMapChrome.gapAboveTabBar != 8, "the retired 8pt gap stays retired")

// iPhone with a 34pt home indicator. The pill is 48pt and sits on 4pt of padding
// above that indicator, so its top is 86pt from the physical bottom.
let screen: ChromeLength = 852
let homeInset: ChromeLength = 34
let pillTopFromBottom = homeInset + StartMapChrome.tabBarBottomPadding + StartMapChrome.tabBarPillHeight
near(StartMapChrome.tabBarPillHeight, 48, "default pill is 2 + 44 + 2")
near(pillTopFromBottom, 86, "default pill top is 86pt from the screen bottom")

let mapMaxY = screen
let tabBarMinY = screen - pillTopFromBottom
let padding = StartMapChrome.startBottomPadding(mapMaxY: mapMaxY, tabBarMinY: tabBarMinY)
near(padding ?? -1, pillTopFromBottom + 16, "measured padding clears the pill by 16pt")
near((padding ?? 0) - pillTopFromBottom, 16, "the gap itself is 16pt")
near(
    StartMapChrome.fallbackStartBottomPadding(safeAreaBottom: homeInset),
    padding ?? -1,
    "before the first measurement, the same 16pt gap still clears the pill"
)

// The TestFlight 60 bug: padding by the device inset plus 10 stops inside the pill.
let oldPadding = homeInset + 10
check(oldPadding < pillTopFromBottom, "safeAreaInsets.bottom + 10 leaves Start under the pill")

// A nonsense pill frame falls back instead of pinning Start to the screen edge.
check(
    StartMapChrome.startBottomPadding(mapMaxY: screen, tabBarMinY: 0) == nil,
    "a pill reported at the top of the screen is ignored"
)
check(
    StartMapChrome.startBottomPadding(mapMaxY: screen, tabBarMinY: screen) == nil,
    "a pill reported flush with the map bottom is ignored"
)

if failures.isEmpty {
    print("start-map-chrome-check: ok")
} else {
    for failure in failures {
        print("FAIL \(failure)")
    }
    exit(1)
}
