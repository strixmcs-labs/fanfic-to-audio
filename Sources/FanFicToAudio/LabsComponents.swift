import SwiftUI

/// The Order's action control (StrixMCS-Design `Button`): a hairline or oxblood surface whose border
/// lifts to oxblood on hover. Text never brightens; keyboard focus shows the gold ring.
struct LabsButtonStyle: ButtonStyle {
    enum Variant { case primary, secondary, ghost }
    var variant: Variant = .secondary
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        LabsButton(configuration: configuration, variant: variant, large: large)
    }
}

private struct LabsButton: View {
    let configuration: ButtonStyle.Configuration
    let variant: LabsButtonStyle.Variant
    let large: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @StateObject private var hover = HoverTracker()

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AppTheme.radius)
        configuration.label
            .font(.system(size: large ? 14 : 13, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(variant == .primary ? Color.white : AppTheme.text)
            .padding(.horizontal, large ? AppTheme.space4 : AppTheme.space3)
            .frame(minHeight: large ? 32 : 24)
            .background(fill, in: shape)
            .overlay(shape.stroke(border, lineWidth: 1))
            .overlay { if isFocused { LabsFocusRing(cornerRadius: AppTheme.radius) } }
            .contentShape(shape)
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : AppTheme.disabledOpacity)
            .focusEffectDisabled()
            .onHover { hover.isHovering = $0 }
            .animation(AppTheme.motion, value: hover.isHovering)
    }

    private var fill: Color {
        switch variant {
        case .primary: AppTheme.structureFill
        case .secondary: AppTheme.raised
        case .ghost: .clear
        }
    }

    private var border: Color {
        if hover.isHovering && isEnabled { return AppTheme.structure }
        switch variant {
        case .primary: return AppTheme.structureFill
        case .secondary: return AppTheme.lineStrong
        case .ghost: return .clear
        }
    }
}

/// The shared keyboard focus ring: a 2px gap, then gold (`--focus-ring`, the one gold exception).
struct LabsFocusRing: View {
    let cornerRadius: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius + 3).stroke(AppTheme.focus, lineWidth: 1).padding(-3)
            .allowsHitTesting(false)
    }
}

/// Hover state for components; this toolchain cannot expand SwiftUI's `@State` macro.
final class HoverTracker: ObservableObject {
    @Published var isHovering = false
}

extension View {
    /// A panel on the field, ringed by a hairline (StrixMCS-Design `Card`). `accentLeft` adds the
    /// 3px oxblood rule used to mark notices.
    func labsCard(padding: CGFloat = AppTheme.space5, accentLeft: Bool = false) -> some View {
        self.padding(padding)
            .background(AppTheme.card, in: RoundedRectangle(cornerRadius: AppTheme.radiusMedium))
            .overlay(alignment: .leading) {
                if accentLeft { Rectangle().fill(AppTheme.structure).frame(width: 3).padding(.vertical, 1) }
            }
            .overlay(RoundedRectangle(cornerRadius: AppTheme.radiusMedium).stroke(AppTheme.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.radiusMedium))
    }

    /// A selectable row: hairline at rest, oxblood edge and accent wash when selected.
    func labsRow(selected: Bool) -> some View {
        self.background(selected ? AppTheme.accentWash : Color.clear, in: RoundedRectangle(cornerRadius: AppTheme.radiusMedium))
            .overlay(RoundedRectangle(cornerRadius: AppTheme.radiusMedium)
                .stroke(selected ? AppTheme.structure : AppTheme.line, lineWidth: 1))
    }
}

/// A short status marker (StrixMCS-Design `Badge`). There are no status colors: state is shown as
/// neutral or accent, with a dot.
struct LabsBadge: View {
    enum Tone { case neutral, accent }
    let label: String
    var tone: Tone = .neutral

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tone == .accent ? AppTheme.oxblood : Color.secondary).frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(label).font(.caption.weight(.medium)).foregroundStyle(AppTheme.text)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .overlay(RoundedRectangle(cornerRadius: AppTheme.radiusSmall)
            .stroke(tone == .accent ? AppTheme.structure : AppTheme.lineStrong, lineWidth: 1))
    }
}
