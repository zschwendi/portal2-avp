#if P2_GAME
import SwiftUI

// Dark Eco launcher look (Port Forge PortForgeStyle/EcoBackground structure:
// dark ink base, raised panels with an accent hairline, capsule actions, a
// slow ribbon backdrop) in this app's own palette, taken from the original
// icon (art/icon/parameters.json): cyan accent, amber glow, deep-blue inks.
// Plain SwiftUI only, so an iPad/iPhone launcher can use it unchanged.
enum PortalStyle {
    static let background = Color(red: 0.020, green: 0.027, blue: 0.059)      // #05070F
    static let surface = Color(red: 0.059, green: 0.086, blue: 0.149)         // #0F1626
    static let raisedSurface = Color(red: 0.094, green: 0.133, blue: 0.227)   // #18223A
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.7)
    static let textOnAccent = Color.black
    static let accent = Color(red: 0.173, green: 0.776, blue: 1.0)            // #2CC6FF
    static let accentGlow = Color(red: 1.0, green: 0.631, blue: 0.122)        // #FFA11F
    static let border = accent.opacity(0.45)
    static let controlFill = raisedSurface
    static let success = Color(red: 0.451, green: 0.902, blue: 0.671)         // #73E6AB
    static let warning = Color(red: 1.0, green: 0.722, blue: 0.349)           // #FFB859
    static let danger = Color(red: 1.0, green: 0.478, blue: 0.580)            // #FF7A94
    static let scrim = Color.black.opacity(0.55)
    static let shadow = accent.opacity(0.3)
    static let inks = [Color(red: 0.051, green: 0.122, blue: 0.298),          // #0D1F4C
                       Color(red: 0.173, green: 0.235, blue: 0.620),          // #2C3C9E
                       Color(red: 0.086, green: 0.439, blue: 0.561)]          // #16708F
    static let cornerRadius: CGFloat = 16
}

extension View {
    func portalThemed() -> some View {
        tint(PortalStyle.accent)
            .foregroundStyle(PortalStyle.textPrimary)
            .preferredColorScheme(.dark)
    }
}

// Slow ribbon backdrop (Dark Eco launcher background), frozen with Reduce
// Motion; never hit-testable or announced.
struct PortalBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date.now

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            let time = reduceMotion ? 0 : max(timeline.date.timeIntervalSince(start), 0)
            Canvas(rendersAsynchronously: true) { context, size in draw(&context, size: size, time: time) }
        }
        .background(PortalStyle.background)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, time: Double) {
        let rect = CGRect(origin: .zero, size: size), inks = PortalStyle.inks
        context.fill(Path(rect), with: .color(PortalStyle.background))
        context.fill(Path(rect), with: .radialGradient(Gradient(colors: [inks[0].opacity(0.55), .clear]),
            center: CGPoint(x: size.width * 0.32, y: size.height * 0.38), startRadius: 0,
            endRadius: max(size.width, size.height) * 0.7))
        var ribbons = context
        ribbons.addFilter(.blur(radius: max(size.height, 1) * 0.035))
        ribbons.blendMode = .plusLighter
        let specs: [(amplitude: Double, frequency: Double, speed: Double, offset: Double, ink: Int, width: Double)] = [
            (0.10, 2.85, 0.18, 0.42, 1, 0.020), (0.08, 3.10, -0.14, 0.58, 0, 0.032), (0.12, 1.85, 0.11, 0.70, 2, 0.014)]
        for spec in specs {
            var path = Path()
            for step in 0...48 {
                let x = Double(step) / 48
                let wave = sin(x * spec.frequency * .pi + time * spec.speed + spec.offset * 7)
                    + 0.35 * sin(x * spec.frequency * 2.3 * .pi - time * spec.speed * 0.7)
                let point = CGPoint(x: x * size.width, y: (spec.offset + wave * spec.amplitude) * size.height)
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            let pulse = 0.55 * (1 + 0.45 * sin(time * 0.62 + spec.offset * 9))
            ribbons.stroke(path, with: .color(inks[spec.ink].opacity(min(1, pulse))),
                           lineWidth: max(size.height * spec.width, 1))
        }
        context.fill(Path(rect), with: .radialGradient(Gradient(colors: [.clear, PortalStyle.scrim]),
            center: CGPoint(x: size.width / 2, y: size.height / 2),
            startRadius: min(size.width, size.height) * 0.3, endRadius: max(size.width, size.height) * 0.75))
    }
}

// Raised panel with an accent hairline (Dark Eco panel).
struct PortalPanel<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .padding(16)
            .background(PortalStyle.raisedSurface.opacity(reduceTransparency ? 1 : 0.9),
                        in: RoundedRectangle(cornerRadius: PortalStyle.cornerRadius + 4, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: PortalStyle.cornerRadius + 4, style: .continuous)
                    .stroke(PortalStyle.border, lineWidth: 1)
            }
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
                .opacity(configuration.isPressed ? 0.75 : 1), in: Capsule())
            .overlay { Capsule().strokeBorder(PortalStyle.border, lineWidth: isEnabled && prominent ? 0 : 1) }
            .opacity(isEnabled ? 1 : 0.6)
            .contentShape(Capsule())
    }
}

// The app name, once, as the shimmering main-menu label (Dark Eco menu label).
struct PortalMenuLabel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let name: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            Text(name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(gradient(at: timeline.date))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(PortalStyle.surface.opacity(0.9), in: Capsule())
                .shadow(color: PortalStyle.shadow, radius: 6)
        }
    }

    private func gradient(at date: Date) -> LinearGradient {
        let accent = PortalStyle.accent
        guard !reduceMotion else { return LinearGradient(colors: [accent, accent], startPoint: .leading, endPoint: .trailing) }
        let location = CGFloat(date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.6) / 2.6 * 4 - 2)
        return LinearGradient(colors: [accent, accent, .white.opacity(0.85), accent, accent],
                              startPoint: UnitPoint(x: location - 1, y: 0.5), endPoint: UnitPoint(x: location + 1, y: 0.5))
    }
}

// Original cover: two glowing elliptical gateways in the icon's colors. No
// game artwork is bundled.
struct PortalCover: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [PortalStyle.inks[0], PortalStyle.background, PortalStyle.inks[2].opacity(0.8)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            GeometryReader { proxy in
                let w = proxy.size.width, h = proxy.size.height
                gateway(rim: PortalStyle.accent, size: CGSize(width: w * 0.34, height: h * 0.46))
                    .position(x: w * 0.3, y: h * 0.56)
                gateway(rim: PortalStyle.accentGlow, size: CGSize(width: w * 0.24, height: h * 0.36))
                    .position(x: w * 0.74, y: h * 0.42)
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }

    private func gateway(rim: Color, size: CGSize) -> some View {
        ZStack {
            Ellipse().fill(RadialGradient(colors: [rim.opacity(0.35), .clear], center: .center,
                                          startRadius: 0, endRadius: max(size.width, size.height) * 0.6))
            Ellipse().stroke(rim, lineWidth: 3).blur(radius: 6)
            Ellipse().stroke(Color.white.opacity(0.9), lineWidth: 1.2)
        }
        .frame(width: size.width, height: size.height)
    }
}
#endif
