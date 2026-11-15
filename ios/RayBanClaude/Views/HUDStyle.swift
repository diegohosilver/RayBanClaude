import SwiftUI
import UIKit

// Hologram HUD like the project page (docs/index.html) and the PC dashboard (channel/dashboard.css).
// All UI colors live here – mode colors stay in VisionMode.

extension Color {
    /// Color from a 24-bit value like 0x49E2FF
    init(rgb: UInt32, opacity: Double = 1) {
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0,
            opacity: opacity
        )
    }

    /// Night blue – base of all surfaces
    static let hudBackground = Color(rgb: 0x02080F)
    /// Slightly lighter base, e.g. for fields
    static let hudSurface = Color(rgb: 0x061522)
    /// Semi-transparent panel over camera image and grid
    static let hudPanel = Color(rgb: 0x081E2E, opacity: 0.78)
    /// Glowing cyan – primary color
    static let hudCyan = Color(rgb: 0x49E2FF)
    /// Gold – secondary color (user, timer, follow-up questions)
    static let hudGold = Color(rgb: 0xFFB648)
    /// Hairlines
    static let hudLine = Color(rgb: 0x133447)
    static let hudLineStrong = Color(rgb: 0x1F5A73)
    /// Text
    static let hudInk = Color(rgb: 0xDFF7FF)
    static let hudMuted = Color(rgb: 0x86A9BB)
    /// Status colors
    static let hudOK = Color(rgb: 0x4DFFB0)
    static let hudWarn = Color(rgb: 0xFFD166)
    static let hudBad = Color(rgb: 0xFF5D73)
    /// Glow, rings and grid (cyan with low opacity)
    static let hudGlow = Color(rgb: 0x49E2FF, opacity: 0.35)
    static let hudRing = Color(rgb: 0x49E2FF, opacity: 0.26)
    static let hudRingStrong = Color(rgb: 0x49E2FF, opacity: 0.62)
    static let hudGrid = Color(rgb: 0x49E2FF, opacity: 0.05)
    /// Center of the mocked-up camera image in demo mode (like the viewfinder on the project page)
    static let hudViewfinder = Color(rgb: 0x1A2129)
}

extension Font {
    /// Technical typeface for status lines, labels and numbers (SF Mono)
    static func hudMono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Wide headline typeface (SF Pro Expanded)
    static func hudDisplay(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight).width(.expanded)
    }
}

/// Small corner radius instead of round cards
enum HUDMetrics {
    static let radius: CGFloat = 3
    static let hairline: CGFloat = 1
}

// MARK: - Panels

/// Angular panel: semi-transparent surface, hairline, optional glowing border, accent edge on the left
/// and color shimmer. Content is not clipped (the reactor rings extend past the edge).
struct HUDPanelModifier: ViewModifier {
    var border: Color = .hudLine
    var glow: Color?
    var accent: Color?
    var tint: Color?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: HUDMetrics.radius, style: .continuous)
        content
            .background {
                ZStack(alignment: .leading) {
                    shape.fill(.ultraThinMaterial).opacity(0.6)
                    shape.fill(Color.hudPanel)
                    if let tint {
                        shape.fill(tint.opacity(0.14))
                    }
                    if let accent {
                        Rectangle().fill(accent).frame(width: 2).shadow(color: accent, radius: 4)
                    }
                }
                .clipShape(shape)
                .shadow(color: glow ?? .clear, radius: glow == nil ? 0 : 14)
            }
            .overlay(shape.strokeBorder(border, lineWidth: HUDMetrics.hairline))
    }
}

extension View {
    func hudPanel(border: Color = .hudLine, glow: Color? = nil, accent: Color? = nil, tint: Color? = nil) -> some View {
        modifier(HUDPanelModifier(border: border, glow: glow, accent: accent, tint: tint))
    }

    /// Soft glow in the content's color
    func hudGlow(_ color: Color = .hudCyan, radius: CGFloat = 6) -> some View {
        shadow(color: color.opacity(0.7), radius: radius)
    }

    /// Background and rows for lists in settings, memory and guides
    func hudList() -> some View {
        scrollContentBackground(.hidden)
            .background(HUDBackdrop().ignoresSafeArea())
            .tint(.hudCyan)
    }

    /// Row surface of a list section
    func hudSection() -> some View {
        listRowBackground(Color.hudPanel)
            .listRowSeparatorTint(.hudLine)
    }
}

/// Corner brackets like the viewfinder on the project page
struct HUDCorners: Shape {
    var length: CGFloat = 12

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: rect.minX, y: rect.minY), 1, 1),
            (CGPoint(x: rect.maxX, y: rect.minY), -1, 1),
            (CGPoint(x: rect.minX, y: rect.maxY), 1, -1),
            (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1),
        ]
        for (point, dx, dy) in corners {
            path.move(to: CGPoint(x: point.x + dx * length, y: point.y))
            path.addLine(to: point)
            path.addLine(to: CGPoint(x: point.x, y: point.y + dy * length))
        }
        return path
    }
}

/// Night-blue base with a fine grid and glow at the top right
struct HUDBackdrop: View {
    var spacing: CGFloat = 40

    var body: some View {
        ZStack {
            Color.hudBackground
            Canvas { context, size in
                var grid = Path()
                for x in stride(from: 0, through: size.width, by: spacing) {
                    grid.move(to: CGPoint(x: x, y: 0))
                    grid.addLine(to: CGPoint(x: x, y: size.height))
                }
                for y in stride(from: 0, through: size.height, by: spacing) {
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(grid, with: .color(.hudGrid), lineWidth: HUDMetrics.hairline)
            }
            RadialGradient(colors: [Color.hudCyan.opacity(0.12), .clear],
                           center: UnitPoint(x: 0.78, y: -0.05), startRadius: 0, endRadius: 420)
        }
        .allowsHitTesting(false)
    }
}

/// Small label in technical type, e.g. section headers
struct HUDLabel: View {
    let text: String
    var color: Color = .hudCyan

    init(_ text: String, color: Color = .hudCyan) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.hudMono(11, weight: .semibold))
            .tracking(1.2)
            .textCase(.uppercase)
            .foregroundStyle(color)
    }
}

extension Section where Parent == HUDLabel, Content: View, Footer == EmptyView {
    /// List section with a HUD label as header
    init(hud title: String, @ViewBuilder content: () -> Content) {
        self.init(content: content, header: { HUDLabel(title) })
    }
}

/// Number of a guide step as a HUD counter
struct HUDStepBadge: View {
    let number: Int

    var body: some View {
        Text("\(number)")
            .font(.hudMono(13, weight: .semibold))
            .foregroundStyle(Color.hudCyan)
            .frame(width: 24, height: 24)
            .background(Color.hudGlow.opacity(0.35), in: RoundedRectangle(cornerRadius: HUDMetrics.radius))
            .overlay(RoundedRectangle(cornerRadius: HUDMetrics.radius).strokeBorder(Color.hudCyan, lineWidth: HUDMetrics.hairline))
            .hudGlow(radius: 4)
    }
}

// MARK: - Buttons

/// Angular button: filled (primary action) or outlined
struct HUDButtonStyle: ButtonStyle {
    var color: Color = .hudCyan
    var filled = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: HUDMetrics.radius, style: .continuous)
        configuration.label
            .font(.hudDisplay(13))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(filled ? Color.hudBackground : color)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(filled ? color : color.opacity(0.08), in: shape)
            .overlay(shape.strokeBorder(color.opacity(filled ? 1 : 0.7), lineWidth: HUDMetrics.hairline))
            .shadow(color: filled ? color.opacity(0.45) : .clear, radius: 10)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - Reactor rings

/// Slowly rotating rings around the microphone button while the app waits for "Hey Claude".
/// With "Reduce Motion" enabled, the rings stand still.
struct ReactorRings: View {
    let diameter: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Rotation periods in seconds as on the project page (26 s, 80 s, 48 s, 18 s)
    private enum Period {
        static let outer = 26.0
        static let ticks = 80.0
        static let dashed = 48.0
        static let arc = 18.0
        static let pulse = 4.2
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            rings(time: time)
        }
        .frame(width: diameter, height: diameter)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func angle(_ time: Double, period: Double, reverse: Bool = false) -> Angle {
        let turns = (time / period).truncatingRemainder(dividingBy: 1)
        return .degrees((reverse ? -360 : 360) * turns)
    }

    private func rings(time: Double) -> some View {
        // 60 tick marks all around, each one seventh of its section wide
        let tickDiameter = diameter * 0.9
        let tickStep: CGFloat = .pi * tickDiameter / 60
        let pulse = reduceMotion ? 1 : 0.72 + 0.28 * cos(2 * Double.pi * time / Period.pulse)
        return ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color.hudGlow, .clear], center: .center,
                                     startRadius: 0, endRadius: diameter / 2))
                .opacity(pulse)
            Circle()
                .trim(from: 0, to: 0.5)
                .stroke(Color.hudRingStrong, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(angle(time, period: Period.outer))
            Circle()
                .stroke(Color.hudRing, style: StrokeStyle(lineWidth: 3, dash: [tickStep * 0.15, tickStep * 0.85]))
                .frame(width: tickDiameter, height: tickDiameter)
                .rotationEffect(angle(time, period: Period.ticks, reverse: true))
            Circle()
                .stroke(Color.hudRing, style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                .frame(width: diameter * 0.8, height: diameter * 0.8)
                .rotationEffect(angle(time, period: Period.dashed, reverse: true))
            Circle()
                .trim(from: 0.5, to: 1)
                .stroke(Color.hudRing, style: StrokeStyle(lineWidth: 4))
                .frame(width: diameter * 0.72, height: diameter * 0.72)
                .rotationEffect(angle(time, period: Period.arc))
        }
    }
}

// MARK: - Navigation bar

@MainActor
enum HUDAppearance {
    /// Navigation bar titles (Settings, Memory …) in technical type with glow
    static func apply() {
        let glow = NSShadow()
        glow.shadowColor = UIColor(Color.hudCyan).withAlphaComponent(0.55)
        glow.shadowBlurRadius = 12
        glow.shadowOffset = .zero
        let bar = UINavigationBar.appearance()
        bar.largeTitleTextAttributes = [
            .font: UIFont.systemFont(ofSize: 30, weight: .semibold, width: .expanded),
            .foregroundColor: UIColor(Color.hudInk),
            .shadow: glow,
        ]
        bar.titleTextAttributes = [
            .font: UIFont.monospacedSystemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: UIColor(Color.hudInk),
        ]
    }
}
