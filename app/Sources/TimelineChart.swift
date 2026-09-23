import SwiftUI
import Charts
import AppKit

/// Photographs per month, split by how their time and timezone were known. Blue and
/// orange are the reference palette's first two categorical slots, validated for
/// colour-vision deficiency in light and dark (ΔE 24.7 protan, 33.6 normal); grey is
/// not a category but absence — "no timezone".
struct TimelineChart: View {
    let months: [Engine.MonthRow]
    @State private var hover: Date?

    static let read = Color(light: 0x2a78d6, dark: 0x3987e5)
    static let worked = Color(light: 0xeb6834, dark: 0xd95926)
    static let unknown = Color(light: 0xc9c8c3, dark: 0x5c5b57)

    private var hovered: Engine.MonthRow? {
        guard let h = hover else { return nil }
        let cal = Calendar(identifier: .gregorian)
        return months.first { cal.isDate($0.date, equalTo: h, toGranularity: .month) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: D.Space.s) {
            HStack(spacing: D.Space.l) {
                legend("Read from the file", Self.read)
                legend("Estimated", Self.worked)
                legend("No timezone", Self.unknown)
                Spacer()
                if let m = hovered {
                    Text("\(label(m.month)) · \(m.total) — \(m.read) read, \(m.worked) estimated, \(m.unknown) no zone")
                        .font(.system(size: 15).monospacedDigit()).foregroundStyle(.secondary)
                } else {
                    Text("Hover a month").font(.system(size: 15)).foregroundStyle(.tertiary)
                }
            }
            Chart {
                ForEach(months) { m in
                    BarMark(x: .value("Month", m.date, unit: .month), y: .value("Photographs", m.read))
                        .foregroundStyle(by: .value("How", "Read from the file"))
                    BarMark(x: .value("Month", m.date, unit: .month), y: .value("Photographs", m.worked))
                        .foregroundStyle(by: .value("How", "Estimated"))
                    BarMark(x: .value("Month", m.date, unit: .month), y: .value("Photographs", m.unknown))
                        .foregroundStyle(by: .value("How", "No timezone"))
                }
                if let m = hovered {
                    RuleMark(x: .value("Month", m.date, unit: .month))
                        .foregroundStyle(Color.primary.opacity(0.12))
                        .lineStyle(StrokeStyle(lineWidth: 8))
                }
            }
            .chartForegroundStyleScale([
                "Read from the file": Self.read, "Estimated": Self.worked, "No timezone": Self.unknown,
            ])
            .chartLegend(.hidden)                    // drawn above, with the hover readout
            .chartXAxis {
                AxisMarks(values: .stride(by: .year, count: max(1, months.count / 60))) { _ in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                    // text wears text colour, never a series or accent colour
                    AxisValueLabel(format: .dateTime.year()).foregroundStyle(Color.secondary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                    AxisValueLabel().foregroundStyle(Color.secondary)
                }
            }
            .chartXSelection(value: $hover)
            .frame(height: 150)
            .accessibilityLabel("Photographs per month, by how their time was known")
        }
    }

    private func legend(_ text: String, _ c: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 10, height: 10)
            Text(text).font(.system(size: 15)).foregroundStyle(.secondary)
        }
    }

    private func label(_ m: String) -> String {
        let months = ["", "Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
        let i = Int(m.suffix(2)) ?? 0
        return "\(i >= 1 && i <= 12 ? months[i] : "?") \(m.prefix(4))"
    }
}

extension Color {
    /// One colour, two appearances: dark mode gets its own validated step, not a flip.
    init(light: UInt32, dark: UInt32) {
        func ns(_ v: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                    blue: CGFloat(v & 0xff) / 255, alpha: 1)
        }
        self = Color(nsColor: NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark) : ns(light)
        })
    }
}
