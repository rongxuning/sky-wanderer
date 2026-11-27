import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
typealias ChromeLength = CGFloat
#else
typealias ChromeLength = Double
#endif

/// Layout for the training start map. The values are plain numbers so
/// `start-map-chrome-check` can compile this file without SwiftUI.
enum StartMapChrome {
    /// Circular primary button. One per screen.
    static let startDiameter: ChromeLength = 72
    /// Gap from the bottom edge of Start to the top edge of the glass pill.
    /// An earlier draft used 8; the map needs the extra air.
    static let gapAboveTabBar: ChromeLength = 16

    static let toolDiameter: ChromeLength = 44
    static let toolGap: ChromeLength = 8
    static let toolLeading: ChromeLength = 16
    static let toolCount = 4

    /// `SkyGlassTabBar` pads 2pt above and below a 44pt item. Dynamic Type can
    /// grow the item; the start button then uses the measured pill top.
    static let tabBarVerticalPadding: ChromeLength = 2
    static let tabBarItemMinHeight: ChromeLength = 44
    /// Padding under the pill inside the home safe-area inset.
    static let tabBarBottomPadding: ChromeLength = 4

    static var tabBarPillHeight: ChromeLength {
        tabBarItemMinHeight + tabBarVerticalPadding * 2
    }

    static var toolColumnHeight: ChromeLength {
        ChromeLength(toolCount) * toolDiameter + ChromeLength(toolCount - 1) * toolGap
    }

    /// Top of the icon column when it is centered on a screen of `screenHeight`.
    /// On an 852pt phone this is 326, so the 200pt column runs to 526.
    static func toolColumnOriginY(screenHeight: ChromeLength) -> ChromeLength {
        max(0, (screenHeight - toolColumnHeight) / 2)
    }

    /// Horizontal midline of the left tool column.
    static func toolColumnMidY(screenHeight: ChromeLength) -> ChromeLength {
        toolColumnOriginY(screenHeight: screenHeight) + toolColumnHeight / 2
    }

    /// Center of the top「类型」tool while docked in the left column.
    static func typeToolHomeCenter(screenHeight: ChromeLength) -> (x: ChromeLength, y: ChromeLength) {
        (
            toolLeading + toolDiameter / 2,
            toolColumnOriginY(screenHeight: screenHeight) + toolDiameter / 2
        )
    }

    /// Screen center — where「类型」lands before the roulette opens.
    static func typeToolScreenCenter(
        screenWidth: ChromeLength,
        screenHeight: ChromeLength
    ) -> (x: ChromeLength, y: ChromeLength) {
        (screenWidth / 2, screenHeight / 2)
    }

    /// `progress` 0 = docked in the tool column, 1 = screen center.
    static func typeToolPosition(
        progress: ChromeLength,
        screenWidth: ChromeLength,
        screenHeight: ChromeLength
    ) -> (x: ChromeLength, y: ChromeLength) {
        let t = max(0, min(1, progress))
        let home = typeToolHomeCenter(screenHeight: screenHeight)
        let center = typeToolScreenCenter(screenWidth: screenWidth, screenHeight: screenHeight)
        return (
            home.x + (center.x - home.x) * t,
            home.y + (center.y - home.y) * t
        )
    }

    /// Hide companions → fly type to center → open roulette.
    static let rouletteOpenCompanionFade: ChromeLength = 0.22
    static let rouletteOpenFly: ChromeLength = 0.42
    /// Close roulette → fly type home → restore companions.
    static let rouletteCloseFade: ChromeLength = 0.18
    static let rouletteCloseFly: ChromeLength = 0.42

    struct Tool: Equatable {
        var symbol: String
        var label: String
    }

    /// Top to bottom. Labels are the accessibility labels; the buttons draw no captions.
    static let tools: [Tool] = [
        Tool(symbol: "figure.run", label: "类型"),
        Tool(symbol: "point.topleft.down.to.point.bottomright.curvepath", label: "路线"),
        Tool(symbol: "person.2", label: "组队"),
        Tool(symbol: "gearshape", label: "设置"),
    ]

    static var typeTool: Tool { tools[0] }
    static var companionTools: [Tool] { Array(tools.dropFirst()) }

    /// Bottom padding that puts Start 16pt above the pill.
    /// `mapMaxY` and `tabBarMinY` share one coordinate space (global).
    /// Returns nil when the pill frame is not a believable clearance, so the
    /// caller can use `fallbackStartBottomPadding` instead.
    static func startBottomPadding(mapMaxY: ChromeLength, tabBarMinY: ChromeLength) -> ChromeLength? {
        let clearance = mapMaxY - tabBarMinY
        guard clearance > 20, clearance < 400 else { return nil }
        return clearance + gapAboveTabBar
    }

    /// Used until the pill's frame is measured.
    /// `safeAreaBottom` on this map is the device inset. It does not include the
    /// custom glass pill, which is why `safeAreaBottom + 10` slides under the bar.
    static func fallbackStartBottomPadding(safeAreaBottom: ChromeLength) -> ChromeLength {
        safeAreaBottom + tabBarBottomPadding + tabBarPillHeight + gapAboveTabBar
    }
}
