import SwiftUI
import AppKit

/// Any asset, and the whole chain behind it (PLAN §5, "why is this here?").
/// Opens on what was *worked out* — the things worth checking — not on the 95% that
/// was simply read off a file.
struct DecisionsView: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        if engine.stats.assets == 0 {
            EmptyState(icon: "questionmark.bubble",
                       title: "Nothing to explain yet",
                       message: "After an analysis, every photograph's date, timezone and place can be traced back to the evidence here.")
        } else {
            HSplitView {
                VStack(spacing: 0) {
                    HStack(spacing: D.Space.s) {
                        Picker("Show", selection: $engine.decisionFilter) {
                            ForEach(Decisions.Filter.allCases) { f in Text(f.rawValue).tag(f) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 170)
                        Spacer()
                        Text(countLabel)
                            .font(.system(size: 15).monospacedDigit()).foregroundStyle(.secondary)
                        Button { engine.exportFindings() } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderless)
                        .help("Export every photograph's findings as CSV or JSON (⌘E)")
                    }
                    .padding(.horizontal, D.Space.m).padding(.vertical, D.Space.s)
                    Divider()
                    if engine.decisionRows.isEmpty {
                        EmptyState(icon: "checkmark.circle",
                                   title: "Nothing here",
                                   message: emptyMessage)
                    } else {
                        List(selection: $engine.decisionSelection) {
                            ForEach(engine.decisionRows) { r in DecisionRow(row: r).tag(r.id) }
                        }
                        .listStyle(.inset)
                    }
                }
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)

                if let id = engine.decisionSelection, let a = engine.asset(id) {
                    DecisionDetail(asset: a, steps: Decisions.explain(a, params: engine.params))
                        .id(id)
                        .frame(minWidth: 380, maxWidth: .infinity)
                } else {
                    EmptyState(icon: "sidebar.right", title: "Select a photograph",
                               message: "See each fact about it, where it came from, and what every copy of it claims.")
                }
            }
            .onAppear { engine.loadDecisions() }
            .onChange(of: engine.decisionFilter) { _, _ in engine.loadDecisions() }
        }
    }

    private var countLabel: String {
        let n = engine.decisionTotal, shown = engine.decisionRows.count
        return n > shown ? "\(shown) of \(n)" : "\(n)"
    }

    private var emptyMessage: String {
        switch engine.decisionFilter {
        case .inferred: return "Every date, timezone and place was read straight off a photograph."
        case .chosen:   return "You haven't settled any timezones yourself."
        default:        return "No photograph matches this filter."
        }
    }
}

struct DecisionRow: View {
    let row: Decisions.Row
    var body: some View {
        HStack(spacing: D.Space.m) {
            Thumb(path: row.path, side: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: D.Space.s) {
                    Text(row.localTime.map(pretty) ?? "Undated")
                        .font(.system(size: 22, weight: .medium)).monospacedDigit()
                    if row.copies > 1 { Badge(text: "×\(row.copies)") }
                }
                HStack(spacing: 4) {
                    ForEach(flags, id: \.self) { SourcePill(text: $0, inferred: true) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    /// Only what was worked out. What was read needs no flag.
    private var flags: [String] {
        var f: [String] = []
        if row.timeSource.hasPrefix("mtime") { f.append("date") }
        if row.zoneSource == "none" { f.append("no zone") }
        else if row.zoneSource == "you chose it" { f.append("zone: you") }
        else if row.zoneSource != "tag" { f.append("zone") }
        if row.placeSource != "measured" && row.placeSource != "none" { f.append("place") }
        return f
    }
}

struct DecisionDetail: View {
    let asset: Decisions.Asset
    let steps: [Decisions.Step]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: D.Space.l) {
                HStack(alignment: .top, spacing: D.Space.l) {
                    Thumb(path: asset.canonical?.path, side: 120)
                    VStack(alignment: .leading, spacing: D.Space.xs) {
                        Text(asset.canonical?.name ?? "—")
                            .font(.system(size: 26, weight: .semibold))
                            .lineLimit(2).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(asset.files.count == 1 ? "One file" : "\(asset.files.count) copies")
                            .font(.system(size: 18)).foregroundStyle(.secondary)
                        if let p = asset.canonical?.path {
                            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) } label: {
                                Label("Show in Finder", systemImage: "arrow.up.forward.square")
                            }
                            .buttonStyle(.link).font(.system(size: 15))
                        }
                    }
                }

                SectionLabel(text: "How each fact was decided")
                VStack(spacing: D.Space.s) {
                    ForEach(steps) { StepCard(step: $0) }
                }

                if let r = asset.resolution, r.lat != nil, Resolver.readPlace(r.placeSource) {
                    RuleMaker(asset: asset)
                }

                SectionLabel(text: "What each copy claims")
                VStack(spacing: D.Space.s) {
                    ForEach(asset.files) { ClaimCard(file: $0) }
                }
                Text("A dash means the file says nothing. PhotoMerge never fills a gap in the file itself — these are exactly the values it found.")
                    .font(.system(size: 15)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
    }
}

struct StepCard: View {
    let step: Decisions.Step

    var body: some View {
        HStack(alignment: .top, spacing: D.Space.m) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 22)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: D.Space.s) {
                    Text(step.topic)
                        .font(.system(size: 15).weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .leading)
                    Text(step.answer)
                        .font(.system(size: 22, weight: .medium)).monospacedDigit()
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: D.Space.s)
                    Text(label)
                        .font(.system(size: 18, weight: .semibold)).tracking(0.4)
                        .foregroundStyle(tint)
                        .fixedSize()
                }
                Text(step.why)
                    .font(.system(size: 18)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 72)
            }
        }
        .padding(D.Space.m)
        .background(.quinary, in: RoundedRectangle(cornerRadius: D.Radius.card))
        .overlay(alignment: .leading) {
            // a thin rule in the provenance colour: scannable down the column
            RoundedRectangle(cornerRadius: 1.5).fill(tint).frame(width: 3).padding(.vertical, 8)
        }
    }

    private var tint: Color {
        switch step.provenance {
        case .read:     return .secondary
        case .inferred: return D.attention
        case .chosen:   return D.keep
        case .unknown:  return Color.secondary.opacity(0.5)
        }
    }
    private var label: String {
        switch step.provenance {
        case .read: return "READ"; case .inferred: return "ESTIMATED"
        case .chosen: return "YOUR CHOICE"; case .unknown: return "UNKNOWN"
        }
    }
    private var icon: String {
        switch step.topic {
        case "Identity": return "square.on.square"
        case "When":     return "clock"
        case "Timezone": return "globe"
        default:         return "mappin.and.ellipse"
        }
    }
}

/// What one copy says about itself, verbatim. Cards rather than a table: five
/// fixed columns forced the pane wider than the window and pushed the sidebar off.
struct ClaimCard: View {
    let file: Decisions.FileClaim

    var body: some View {
        VStack(alignment: .leading, spacing: D.Space.s) {
            HStack(spacing: D.Space.s) {
                if file.role == "canonical" { Badge(text: "KEEP", color: D.keep) }
                if file.role == "companion" { Badge(text: "CLIP", color: .blue) }
                Text(file.name)
                    .font(.system(size: 21, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Text("\(file.width)×\(file.height) · \(byteString(file.bytes))")
                    .font(.system(size: 18)).monospacedDigit().foregroundStyle(.tertiary)
                    .lineLimit(1).fixedSize()
            }
            Grid(alignment: .leading, horizontalSpacing: D.Space.m, verticalSpacing: 4) {
                GridRow {
                    field("Captured", file.capturedAt.map(pretty))
                    field("Offset", file.utcOffset)
                }
                GridRow {
                    field("GPS", file.lat.map { prettyPlace($0, file.lon ?? 0) + (Gazetteer.describe($0, file.lon ?? 0).map { " · " + $0 } ?? "") })
                    field("Camera", file.model)
                }
                if file.utcInstant != nil || file.nameClock != nil || file.sidecar != nil || file.album != nil {
                    GridRow {
                        field("Instant", file.utcInstant.map {
                            pretty(Resolver.wallClock($0, offset: 0)) + " UTC · " + (file.utcSource ?? "")
                        })
                        field("Name", file.nameClock.map { pretty($0) + " · " + (file.nameRule ?? "") })
                    }
                    GridRow {
                        field("Sidecar", file.sidecar)
                        field("Folder", file.album)
                    }
                }
            }
        }
        .padding(D.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary, in: RoundedRectangle(cornerRadius: D.Radius.card))
    }

    @ViewBuilder private func field(_ label: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(.system(size: 18, weight: .semibold)).foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .leading)
            Text(value ?? "—")
                .font(.system(size: 20)).monospacedDigit()
                .foregroundStyle(value == nil ? .tertiary : .primary)
                .lineLimit(1).truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}


/// "Use this place for…": turn one located photograph into a rule for the ones
/// nothing else could place — its folder, or a range of days.
struct RuleMaker: View {
    @EnvironmentObject var engine: Engine
    let asset: Decisions.Asset
    @State private var open = false
    @State private var byFolder = true
    @State private var from = Date()
    @State private var to = Date()

    private var folder: String? { asset.files.compactMap(\.album).first }
    private var day: Int? { Resolver.dayNumber(asset.resolution?.localTime) }

    var body: some View {
        VStack(alignment: .leading, spacing: D.Space.s) {
            Button { open.toggle() } label: {
                Label("Use this place for photographs nothing else can place…", systemImage: "mappin.and.ellipse")
                    .font(.system(size: 15).weight(.medium))
            }
            .buttonStyle(.link)
            if open {
                Card {
                    VStack(alignment: .leading, spacing: D.Space.s) {
                        if let folder {
                            Segments(selection: $byFolder, items: [(true, "Everything in “\(folder)”"), (false, "A range of days")])
                        }
                        if folder == nil || !byFolder {
                            HStack {
                                DatePicker("From", selection: $from, displayedComponents: .date)
                                DatePicker("to", selection: $to, displayedComponents: .date)
                            }
                            .font(.system(size: 15))
                        }
                        Text("Only photographs with no place from any evidence are affected — never one with its own GPS, a sidecar, or a nearby photo to go by. Remove the rule any time in Dates & places.")
                            .font(.system(size: 15)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Spacer()
                            Button("Cancel") { open = false }.controlSize(.regular)
                            Button("Add rule") {
                                if let folder, byFolder {
                                    engine.addRule(from: asset, folder: folder, from: nil, to: nil)
                                } else {
                                    engine.addRule(from: asset, folder: nil, from: dayNumber(from), to: dayNumber(to))
                                }
                                open = false
                            }
                            .controlSize(.regular).buttonStyle(.bigProminent)
                            .disabled(engine.progress.running || (!(folder != nil && byFolder) && from > to))
                        }
                    }
                }
            }
        }
        .onAppear {
            if let d = day { let date = Date(timeIntervalSince1970: Double(d) * 86400 + 43200); from = date; to = date }
        }
    }

    private func dayNumber(_ d: Date) -> Int? {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return Resolver.dayNumber(String(format: "%04d:%02d:%02d 12:00:00", c.year ?? 0, c.month ?? 0, c.day ?? 0))
    }
}
