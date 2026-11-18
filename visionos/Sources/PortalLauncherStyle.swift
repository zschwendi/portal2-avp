#if P2_GAME
import SwiftUI

// Port Forge library surfaces in Portal's light blue-and-orange palette.
enum PortalStyle {
    static let background = Color.white
    static let surface = Color.white
    static let raisedSurface = Color.white
    static let textPrimary = color(0x17283D)
    static let textSecondary = color(0x4C6178)
    static let textOnAccent = Color.white
    static let accent = color(0x005CB8)
    static let accentGlow = color(0xB54708)
    static let border = color(0xD8E2ED)
    static let controlFill = color(0xEDF4FC)
    static let success = color(0x24734E)
    static let warning = accentGlow
    static let danger = color(0xA52842)
    static let shadow = textPrimary.opacity(0.09)
    static let cornerRadius: CGFloat = 16

    static func color(_ rgb: UInt32) -> Color {
        Color(red: Double((rgb >> 16) & 0xFF) / 255,
              green: Double((rgb >> 8) & 0xFF) / 255,
              blue: Double(rgb & 0xFF) / 255)
    }
}

extension View {
    func portalThemed() -> some View {
        tint(PortalStyle.accent)
            .foregroundStyle(PortalStyle.textPrimary)
            .preferredColorScheme(.light)
    }
}

struct PortalBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [.white, PortalStyle.color(0xF4F7FC)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [PortalStyle.accent.opacity(0.10), .clear],
                           center: .bottomLeading, startRadius: 0, endRadius: 430)
            RadialGradient(colors: [PortalStyle.color(0xEF7622).opacity(0.10), .clear],
                           center: .topTrailing, startRadius: 0, endRadius: 380)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct PortalPanel<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        let panel = RoundedRectangle(cornerRadius: PortalStyle.cornerRadius + 4, style: .continuous)
        content
            .padding(16)
            .background(PortalStyle.raisedSurface, in: panel)
            .overlay { panel.strokeBorder(PortalStyle.border, lineWidth: 1) }
    }
}

struct PortalCapsuleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var prominent = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .foregroundStyle(!isEnabled ? PortalStyle.textSecondary : prominent ? PortalStyle.textOnAccent : PortalStyle.accent)
            .background((isEnabled && prominent ? PortalStyle.accent : PortalStyle.controlFill)
                .opacity(configuration.isPressed ? 0.78 : 1), in: Capsule())
            .overlay { Capsule().strokeBorder(PortalStyle.border, lineWidth: isEnabled && prominent ? 0 : 1) }
            .opacity(isEnabled ? 1 : 0.65)
            .contentShape(Capsule())
    }
}

struct PortalMenuLabel: View {
    let name: String

    var body: some View {
        HStack(spacing: 9) {
            HStack(spacing: 3) {
                Capsule().fill(PortalStyle.accent)
                Capsule().fill(PortalStyle.color(0xEF7622))
            }
            .frame(width: 13, height: 12)
            .accessibilityHidden(true)
            Text(name).font(.caption.weight(.semibold))
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                .foregroundStyle(PortalStyle.textSecondary)
                .accessibilityHidden(true)
        }
        .foregroundStyle(PortalStyle.textPrimary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(PortalStyle.surface, in: Capsule())
        .overlay { Capsule().strokeBorder(PortalStyle.border, lineWidth: 1) }
    }
}

// Original portal linework for the Library card.
struct PortalCover: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [.white, PortalStyle.color(0xE8EEF6)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            GeometryReader { proxy in
                let width = proxy.size.width
                let height = proxy.size.height
                gateway(rim: PortalStyle.accent, width: width * 0.42, height: height * 0.46)
                    .rotationEffect(.degrees(-19))
                    .position(x: width * 0.38, y: height * 0.58)
                gateway(rim: PortalStyle.color(0xEF7622), width: width * 0.34, height: height * 0.38)
                    .rotationEffect(.degrees(-19))
                    .position(x: width * 0.66, y: height * 0.40)
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }

    private func gateway(rim: Color, width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            Ellipse().fill(.white.opacity(0.7))
            Ellipse().strokeBorder(rim.opacity(0.20), lineWidth: width * 0.21).blur(radius: 8)
            Ellipse().strokeBorder(rim, lineWidth: width * 0.12)
            Ellipse().inset(by: width * 0.058).strokeBorder(.white.opacity(0.75), lineWidth: 1)
        }
        .frame(width: width, height: height)
    }
}
#endif
