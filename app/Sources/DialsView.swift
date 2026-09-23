import SwiftUI

/// Every dial shows what it would do to *this* collection before it is applied,
/// with samples ranked by weakest evidence (PLAN §8). Nothing here writes until
/// Apply, and Apply writes only the catalog.
struct DialsView: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        if engine.stats.assets == 0 {
            EmptyState(icon: "slider.horizontal.3", title: "Nothing to tune yet",
                       message: "Once a folder is analysed, each dial here previews its effect on your photographs before you apply it.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: D.Space.l) {
                    MatchingDial()
                    PlaceDials()
                    machine
                }
                .padding(20)
                .frame(maxWidth: 1150, alignment: .leading)
            }
        }
    }

    private var machine: some View {
        VStack(alignment: .leading, spacing: D.Space.s) {
            SectionLabel(text: "This machine")
            Card {
                VStack(alignment: .leading, spacing: D.Space.xs) {
                    LabeledContent("Workers", value: "\(engine.workerCount) performance cores")
                    Text("Measured on this hardware: using every logical core is about 7% slower than using the performance cores alone.")
                        .font(.system(size: 15)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: matching

/// How alike two stills must look to be compared — with what each setting would
/// do to this collection, tried out before it is applied. Also the Duplicates step.
struct MatchingDial: View {
    @EnvironmentObject var engine: Engine
    var showLabel = true
    @State private var radius = 4

    var body: some View {
        VStack(alignment: .leading, spacing: D.Space.s) {
            if showLabel { SectionLabel(text: "Matching duplicates") }
            Card {
                VStack(alignment: .leading, spacing: D.Space.m) {
                    Text("How similar two stills must look before the pixels are compared")
                        .font(.system(size: 22, weight: .semibold))
                    Segments(selection: $radius, items: [(0, "Identical"), (2, "Tight"), (4, "Recommended"), (6, "Loose"), (8, "Very loose")])

                    Text("A **recall** dial, not a safety dial: every candidate is still checked for a shared capture instant and against the pixels, so widening it finds more without merging more wrongly. Videos are matched separately and are unaffected.")
                        .font(.system(size: 15)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let pv = engine.radiusPreview {
                        RadiusTable(rows: pv.rows, selected: radius, applied: engine.radius)
                        samples(pv.samples[radius] ?? [])
                    } else {
                        HStack(spacing: D.Space.s) {
                            ProgressView().controlSize(.regular)
                            Text("Trying every setting on your photographs…")
                                .font(.system(size: 15)).foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        Spacer()
                        Button(radius == engine.radius ? "Applied" : "Apply and regroup") {
                            engine.applyRadius(radius)
                        }
                        .buttonStyle(.bigProminent)
                        .disabled(radius == engine.radius || engine.progress.running)
                    }
                }
            }
        }
        .onAppear { radius = engine.radius; engine.loadDialPreviews() }
    }

    @ViewBuilder private func samples(_ pairs: [Clusterer.Pair]) -> some View {
        if pairs.isEmpty {
            Text(radius == 0 ? "At this setting only byte- or pixel-identical files are merged."
                             : "Nothing at this setting is merged or put to you by perceptual distance.")
                .font(.system(size: 15)).foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .leading, spacing: D.Space.s) {
                Text("Samples — the closest calls first. Check these before trusting the setting.")
                    .font(.system(size: 15).weight(.medium)).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: D.Space.m) {
                        ForEach(Array(pairs.prefix(8).enumerated()), id: \.offset) { _, p in
                            SamplePair(pair: p)
                        }
                    }
                }
            }
        }
    }


}

// MARK: places

/// How far a photograph without GPS may borrow a place from its day or its
/// neighbours, previewed on this collection. Also the Time & place step.
struct PlaceDials: View {
    @EnvironmentObject var engine: Engine
    var showLabel = true

    var body: some View {
        VStack(alignment: .leading, spacing: D.Space.s) {
            if showLabel { SectionLabel(text: "Places") }
            Card {
                VStack(alignment: .leading, spacing: D.Space.m) {
                    DialSlider(title: "Same day, same place",
                               detail: "A photograph without GPS takes the day's location when every fix that day lies within",
                               value: $engine.draftParams.dayRadiusKM, range: 5...100, step: 5,
                               unit: "km", applied: engine.params.dayRadiusKM)
                    Divider()
                    DialSlider(title: "Borrow a nearby fix",
                               detail: "Otherwise it takes the position of the closest photograph with GPS, if that was taken within",
                               value: $engine.draftParams.travelMinutes, range: 0...240, step: 15,
                               unit: "min", applied: engine.params.travelMinutes)

                    if let pr = engine.placePreview {
                        PlaceSummary(result: pr, now: engine.stats.located, total: engine.stats.assets)
                        if !pr.changes.isEmpty {
                            Text("What would change — places gained on the thinnest evidence first.")
                                .font(.system(size: 15).weight(.medium)).foregroundStyle(.secondary)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: D.Space.m) {
                                    ForEach(pr.changes.prefix(10)) { PlaceSample(change: $0) }
                                }
                            }
                        }
                    }

                    HStack {
                        Button("Defaults") { engine.draftParams = Resolver.Params() }
                            .disabled(engine.draftParams == Resolver.Params())
                        Spacer()
                        Button(engine.draftParams == engine.params ? "Applied" : "Apply") {
                            engine.applyPlaces()
                        }
                        .buttonStyle(.bigProminent)
                        .disabled(engine.draftParams == engine.params || engine.progress.running)
                    }
                }
            }
        }
        .onAppear { engine.previewPlaces() }
        .onChange(of: engine.draftParams) { _, _ in engine.previewPlaces() }
    }
}

// MARK: - pieces

struct RadiusTable: View {
    let rows: [Preview.RadiusRow]
    let selected: Int
    let applied: Int

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: D.Space.l, verticalSpacing: 6) {
            GridRow {
                Text("Setting").gridColumnAlignment(.leading)
                Text("Photos merged"); Text("Asked you"); Text("Look-alikes rejected")
                Text("Burst frames kept apart"); Text("Longest chain")
            }
            .font(.system(size: 18, weight: .semibold)).foregroundStyle(.tertiary)
            ForEach(rows) { r in
                GridRow {
                    HStack(spacing: 4) {
                        Text(label(r.radius))
                        if r.radius == applied { Badge(text: "APPLIED", color: D.keep) }
                    }
                    .gridColumnAlignment(.leading)
                    Text("\(r.duplicates)")
                    Text("\(r.variants)").foregroundStyle(r.variants > 0 ? D.attention : .primary)
                    Text("\(r.rejected)")
                    Text("\(r.bursts)")
                    Text("\(r.longestChain)")
                }
                .font(.system(size: 21, weight: r.radius == selected ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(r.radius == selected ? .primary : .secondary)
            }
        }
        .padding(D.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: D.Radius.small))
        .help("A longest chain that stays flat as the setting widens means every merge is still being checked. If it climbed, something would have stopped checking.")
    }

    private func label(_ r: Int) -> String {
        switch r {
        case 0: return "Identical"; case 2: return "Tight"; case 4: return "Recommended"
        case 6: return "Loose"; default: return "Very loose"
        }
    }
}

struct SamplePair: View {
    @EnvironmentObject var engine: Engine
    let pair: Clusterer.Pair

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                Thumb(path: engine.path(file: pair.a), side: 76)
                Thumb(path: engine.path(file: pair.b), side: 76)
            }
            HStack(spacing: 4) {
                Badge(text: pair.outcome == .merged ? "MERGED" : "ASKED YOU",
                      color: pair.outcome == .merged ? D.keep : D.attention)
                if let hi = pair.maeHi {
                    Text(String(format: "diff %.1f", hi))
                        .font(.system(size: 18)).monospacedDigit().foregroundStyle(.tertiary)
                }
            }
        }
    }
}

struct DialSlider: View {
    let title: String, detail: String
    @Binding var value: Double
    let range: ClosedRange<Double>, step: Double
    let unit: String, applied: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 22, weight: .semibold))
                Spacer()
                Text("\(Int(value)) \(unit)")
                    .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(value == applied ? .primary : D.attention)
                if value != applied {
                    Text("was \(Int(applied))").font(.system(size: 15)).foregroundStyle(.tertiary)
                }
            }
            Text(detail + " \(Int(value)) \(unit).")
                .font(.system(size: 15)).foregroundStyle(.secondary)
            Slider(value: $value, in: range, step: step)
        }
    }
}

struct PlaceSummary: View {
    let result: Preview.PlaceResult
    let now: Int, total: Int

    var body: some View {
        let gained = result.changes.filter { $0.kind == .gained }.count
        let lost = result.changes.filter { $0.kind == .lost }.count
        let moved = result.changes.count - gained - lost
        HStack(spacing: 22) {
            Metric(value: "\(result.located)", label: "located",
                   fraction: total > 0 ? Double(result.located) / Double(total) : nil)
            Metric(value: "+\(gained)", label: "gained", tint: gained > 0 ? D.attention : nil)
            Metric(value: "−\(lost)", label: "lost")
            Metric(value: "\(moved)", label: "moved", tint: moved > 0 ? D.attention : nil)
            Spacer()
            if result.changes.isEmpty {
                Text("No photograph's place would change.")
                    .font(.system(size: 15)).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, D.Space.xs)
    }
}

struct PlaceSample: View {
    @EnvironmentObject var engine: Engine
    let change: Preview.PlaceChange

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Thumb(path: engine.path(cluster: change.clusterID), side: 96)
            Badge(text: change.kind.rawValue.uppercased(),
                  color: change.kind == .lost ? .secondary : D.attention)
            Text(change.localTime.map(pretty) ?? "—")
                .font(.system(size: 18)).monospacedDigit()
            Text(change.kind == .moved ? String(format: "%.1f km", change.km ?? 0) : change.after)
                .font(.system(size: 18)).foregroundStyle(.secondary)
                .lineLimit(1).frame(width: 96, alignment: .leading)
        }
        .onTapGesture { engine.inspect(change.clusterID) }
        .help("Open in Decisions")
    }
}
