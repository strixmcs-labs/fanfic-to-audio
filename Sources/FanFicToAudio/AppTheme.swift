import AppKit
import SwiftUI

/// StrixMCS Labs design tokens for a native Labs app (StrixMCS-Design readme, rules 7–23).
/// Native Labs apps follow the system appearance and typeface: light mode is a white field with
/// Labs oxblood; dark mode is the Order's black field with Labs wine for accent text. Oxblood is
/// structure (edges, rules, the primary button); gold is the keyboard focus ring and nothing else.
enum AppTheme {
    // MARK: Color

    /// The window field: white in light mode, absolute black in dark mode.
    static let background = dynamic(light: 0xFFFFFF, dark: 0x000000)
    /// Raised panels on the field: white with a hairline in light mode, Near in dark mode.
    static let card = dynamic(light: 0xFFFFFF, dark: 0x0B0B0B)
    /// The second surface step, for selected or emphasized panels without a shadow.
    static let raised = dynamic(light: 0xF6F6F6, dark: 0x121212)
    /// Hairline rules and borders; depth is the hairline ring, never a shadow.
    static let line = dynamic(light: 0xE2E2E2, dark: 0x1C1C1C)
    static let lineStrong = dynamic(light: 0xCCCCCC, dark: 0x262626)
    /// Display and label text.
    static let text = dynamic(light: 0x111111, dark: 0xF7F7F7)
    /// Accent for icons, tints, and selected text: Labs oxblood #650F20 (12.8:1 on white) in light
    /// mode, Labs wine #D37181 (4.5:1 or better on black) in dark mode.
    static let oxblood = dynamic(light: 0x650F20, dark: 0xD37181)
    /// Structural oxblood for borders, active edges, and hover lifts.
    static let structure = dynamic(light: 0x650F20, dark: 0x6E0808)
    /// The primary button fill; its label is always white.
    static let structureFill = dynamic(light: 0x650F20, dark: 0x4A0404)
    /// A faint accent field for selected rows and notices.
    static let accentWash = dynamic(light: 0x650F20, dark: 0x4A0404, alpha: 0.07)
    /// Gold, used only for the keyboard focus ring (rule 10).
    static let focus = Color(red: 188 / 255.0, green: 166 / 255.0, blue: 135 / 255.0)
    /// Book and cover artwork only (rule 16).
    static let bookGradient = LinearGradient(colors: [Color(red: 143 / 255.0, green: 48 / 255.0, blue: 64 / 255.0),
                                                      Color(red: 101 / 255.0, green: 15 / 255.0, blue: 32 / 255.0)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)

    // MARK: Shape, spacing, and motion

    /// Radii stay within 3–6px; only toggles are pill-shaped (rules 17–18).
    static let radiusSmall: CGFloat = 3
    static let radius: CGFloat = 4
    static let radiusMedium: CGFloat = 6
    /// The quiet 4px grid.
    static let space1: CGFloat = 4, space2: CGFloat = 8, space3: CGFloat = 12, space4: CGFloat = 16
    static let space5: CGFloat = 20, space6: CGFloat = 24, space8: CGFloat = 32
    /// Measured motion, no bounce: cubic-bezier(.2, 0, 0, 1) at 180ms.
    static let motion = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.18)
    /// Disabled controls drop to about 45% opacity.
    static let disabledOpacity = 0.45

    private static func dynamic(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> Color {
        func color(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? color(dark) : color(light)
        })
    }
}
