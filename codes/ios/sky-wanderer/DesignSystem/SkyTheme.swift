import SwiftUI

/// Light-first Sky 1.0.0 tokens.
///
/// Numbers match `docs/design/tokens.json` and `docs/design/sky-design-system.md`.
/// New screens read `SkyTheme`. `SkyHomeColor`, `LoginColor`, and the `omni*` palette stay until those screens migrate.
enum SkyTheme {
    enum Color {
        static let primary = SkyHex.color(0x1E88FE)
        /// Each RGB channel of `primary` multiplied by 0.92.
        static let primaryPressed = SkyHex.color(0x1C7DEA)
        static let background = SkyHex.color(0xFFFFFF)
        static let grouped = SkyHex.color(0xF5F5F7)
        static let card = SkyHex.color(0xFFFFFF)
        static let cardBorder = SkyHex.color(0xE4F1FF)
        static let ink = SkyHex.color(0x1C1C1E)
        static let secondary = SkyHex.color(0x8E8E93)
        static let tertiary = SkyHex.color(0xC6C6C8)
        static let separator = SkyHex.color(0xC6C6C8)
        static let success = SkyHex.color(0x34C759)
        static let warning = SkyHex.color(0xFF9500)
        static let danger = SkyHex.color(0xFF3B30)
        static let onPrimary = SkyHex.color(0xFFFFFF)
        static let chartTrack = SkyHex.color(0x1E88FE)
        static let chartNeutral = SkyHex.color(0x8E8E93)
        static let chartNeutralMuted = SkyHex.color(0xC6C6C8)
    }

    /// SF Pro through the system font. Text styles follow Dynamic Type.
    enum Font {
        static let fontFamily = "SF Pro"
        static let dynamicType = true

        static let largeTitle = skyFont(.largeTitle, .bold) // 34
        static let title = skyFont(.title, .bold) // 28
        static let title2 = skyFont(.title2, .bold) // 22
        static let title3 = skyFont(.title3, .semibold) // 20
        static let headline = skyFont(.headline, .semibold) // 17
        static let body = skyFont(.body, .regular) // 17
        static let callout = skyFont(.callout, .regular) // 16
        static let subheadline = skyFont(.subheadline, .regular) // 15
        static let footnote = skyFont(.footnote, .regular) // 13
        static let caption = skyFont(.caption, .regular) // 12

        /// Metric figures use the surrounding style's size at `valueWeight`. Units use `unitStyle` in `unitColor`.
        enum Metric {
            static let valueWeight = SwiftUI.Font.Weight.semibold
            static let unitStyle = SkyTheme.Font.footnote
            static let unitColor = SkyTheme.Color.secondary
        }
    }

    enum Spacing {
        static let scale: [CGFloat] = [4, 8, 12, 16, 24, 32]
        static let screenInset: CGFloat = 16
        static let cardPadding: CGFloat = 16
        static let related: CGFloat = 8
        static let section: CGFloat = 24
        static let listRowMin: CGFloat = 52
        static let listRowMax: CGFloat = 64
        static let touchMin: CGFloat = 44
        static let controlGap: CGFloat = 8
    }

    /// Point radii use a continuous corner. `button` is a capsule, matching `tokens.json` (`"capsule"`).
    enum Radius {
        static let chip: CGFloat = 12
        static let card: CGFloat = 16
        static let sheet: CGFloat = 24
        static let button = Button.capsule

        enum Button {
            case capsule
        }
    }

    enum Shadow {
        struct Style {
            /// Opaque shadow color. Combine with `opacity` at the call site.
            let color: SwiftUI.Color
            let opacity: Double
            let y: CGFloat
            let radius: CGFloat
        }

        static let card = Style(
            color: SkyHex.color(0x000000),
            opacity: 0.1,
            y: 6,
            radius: 14
        )
    }
}

private enum SkyHex {
    static func color(_ hex: UInt32) -> SwiftUI.Color {
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        return SwiftUI.Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }
}

private func skyFont(_ style: SwiftUI.Font.TextStyle, _ weight: SwiftUI.Font.Weight) -> SwiftUI.Font {
    SwiftUI.Font.system(style, design: .default, weight: weight)
}
