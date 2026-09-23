import SwiftUI
import AppKit

/// One place for the visual language, so spacing, type and colour stay consistent
/// as the app grows. Values are a scale, not arbitrary — every gap is a multiple
/// of 4. The look is quiet: a warm canvas, white cards that lift a little, one
/// accent, and orange only where the app worked something out or wants a look.
enum D {
    enum Space {
        static let xs: CGFloat = 4
        static let s:  CGFloat = 8
        static let m:  CGFloat = 12
        static let l:  CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }
    enum Radius {
        static let small: CGFloat = 8
        static let card:  CGFloat = 14
    }
    /// Orange means "inferred, or wants your attention". Never decoration.
    static let attention = Color.orange
    static let keep = Color.green

    /// The window's ground: warm off-white by day, deep grey by night.
    static let canvas = Color.adaptive(light: NSColor(calibratedRed: 0.965, green: 0.961, blue: 0.953, alpha: 1),
                                       dark: NSColor(calibratedWhite: 0.11, alpha: 1))
    /// What cards and controls are made of.
    static let surface = Color.adaptive(light: .white, dark: NSColor(calibratedWhite: 0.17, alpha: 1))
    /// The finest line that still reads as an edge.
    static let hairline = Color.adaptive(light: NSColor(calibratedWhite: 0, alpha: 0.08),
                                         dark: NSColor(calibratedWhite: 1, alpha: 0.10))
    /// The accent, with a little depth for the one thing to press.
    static var accentGradient: LinearGradient {
        LinearGradient(colors: [Color.accentColor.opacity(0.92), Color.accentColor],
                       startPoint: .top, endPoint: .bottom)
    }
    /// A meter's fill.
    static var meterGradient: LinearGradient {
        LinearGradient(colors: [Color.accentColor.opacity(0.75), Color.accentColor],
                       startPoint: .leading, endPoint: .trailing)
    }
}

extension Color {
    /// A colour that follows the appearance, light or dark, without a catalog.
    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { a in
            a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

// MARK: - metric

/// A headline number. The label is what it means; the meter, when present, shows
/// how much of the whole it covers — a percentage you can read without arithmetic.
struct Metric: View {
    let value: String
    let label: String
    var tint: Color? = nil
    var fraction: Double? = nil
    var help: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint ?? .primary)
                .contentTransition(.numericText())
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            Text(label.uppercased())
                .font(.system(size: 14, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.tertiary)
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            if let fraction {
                Capsule()
                    .fill(.quaternary)
                    .frame(width: 52, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(D.meterGradient))
                            .frame(width: 52 * max(0, min(1, fraction)), height: 4)
                    }
                    .padding(.top, 2)
            }
        }
        .help(help ?? "")
    }
}

// MARK: - containers

/// A white card that lifts a little off the canvas.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(D.Space.l)
            .background(D.surface, in: RoundedRectangle(cornerRadius: D.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: D.Radius.card).strokeBorder(D.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        HStack(spacing: D.Space.s) {
            RoundedRectangle(cornerRadius: 1.5).fill(Color.accentColor).frame(width: 3, height: 14)
            Text(text.uppercased())
                .font(.system(size: 15, weight: .semibold))
                .tracking(1.0)
                .foregroundStyle(.secondary)
        }
    }
}

/// A small pill stating where a fact came from. Grey when it was read off the file,
/// orange when the app worked it out — the distinction the whole product rests on.
struct SourcePill: View {
    let text: String
    let inferred: Bool
    var body: some View {
        Text(text)
            .font(.system(size: 16, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(inferred ? D.attention.opacity(0.14) : Color.secondary.opacity(0.10),
                        in: Capsule())
            .foregroundStyle(inferred ? D.attention : .secondary)
    }
}

/// Buttons at the size of the text around them. macOS's bordered buttons keep
/// their own 13-point label whatever font the view around them sets, and the
/// segmented control ignores fonts altogether, so both are drawn here.
struct BigButton: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, prominent: prominent)
    }
    private struct Styled: View {
        let configuration: Configuration
        let prominent: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false
        var body: some View {
            configuration.label
                .font(.system(size: 18, weight: prominent ? .semibold : .medium))
                .padding(.horizontal, 16).padding(.vertical, 8)
                .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .background {
                    if prominent {
                        RoundedRectangle(cornerRadius: 10).fill(D.accentGradient)
                            .brightness(hover ? 0.06 : 0)
                            .shadow(color: Color.accentColor.opacity(0.28), radius: hover ? 8 : 4, y: 2)
                    } else {
                        RoundedRectangle(cornerRadius: 10).fill(hover ? AnyShapeStyle(.quaternary) : AnyShapeStyle(D.surface))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(D.hairline, lineWidth: 1))
                            .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
                    }
                }
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.12), value: hover)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}
extension ButtonStyle where Self == BigButton {
    static var bigBordered: BigButton { BigButton() }
    static var bigProminent: BigButton { BigButton(prominent: true) }
}

/// A segmented choice, drawn to match the type: a grey track, and the chosen
/// segment a white pill that floats a little.
struct Segments<T: Hashable>: View {
    @Binding var selection: T
    let items: [(value: T, label: String)]
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                let on = selection == it.value
                Button { withAnimation(.easeOut(duration: 0.15)) { selection = it.value } } label: {
                    Text(it.label)
                        .font(.system(size: 18, weight: on ? .semibold : .regular))
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .foregroundStyle(on ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 9).fill(D.surface)
                                    .shadow(color: .black.opacity(0.10), radius: 3, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06)))
    }
}

struct Badge: View {
    let text: String
    var color: Color = .secondary
    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .bold))
            .tracking(0.4)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }
}

/// A percentage as a ring, the number inside it.
struct Ring: View {
    let fraction: Double
    var size: CGFloat = 76
    var tint: Color? = nil
    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.07), lineWidth: 7)
            Circle().trim(from: 0, to: max(0, min(1, fraction)))
                .stroke(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(D.meterGradient),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.5), value: fraction)
            Text("\(Int((fraction * 100).rounded()))%")
                .font(.system(size: size * 0.29, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(width: size, height: size)
    }
}

// MARK: - empty state

struct EmptyState<Actions: View>: View {
    let icon: String
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: D.Space.l) {
            ZStack {
                Circle().fill(Color.primary.opacity(0.05)).frame(width: 104, height: 104)
                Image(systemName: icon)
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: D.Space.xs) {
                Text(title).font(.system(size: 26, weight: .semibold))
                Text(message)
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    // A definite width: with only a maximum, a split view measuring the
                    // pane at near-zero width got a message one word per line, thousands
                    // of points tall, and every pane with a two-line message pushed the
                    // sidebar, scoreboard and status bar out of the window.
                    .frame(width: 420)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyState where Actions == EmptyView {
    init(icon: String, title: String, message: String) {
        self.init(icon: icon, title: title, message: message) { EmptyView() }
    }
}
