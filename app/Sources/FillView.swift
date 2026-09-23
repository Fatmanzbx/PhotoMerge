import SwiftUI
import AppKit

/// Photographs with no date or no place, in a grid, for filling in by hand — many
/// at once. Selection works as in Finder: click, ⌘-click to toggle, ⇧-click for a
/// range, or drag a box across the grid (hold ⌘ or ⇧ to add to what is selected).
struct FillView: View {
    @EnvironmentObject var engine: Engine
    @State private var selected = Set<Int>()
    @State private var anchor: Int?
    @State private var side: CGFloat = 104
    // rubber band
    @State private var frames: [Int: CGRect] = [:]
    @State private var band: CGRect?
    @State private var bandBase = Set<Int>()

    var body: some View {
        if engine.stats.assets == 0 {
            EmptyState(icon: "square.and.pencil", title: "Nothing to fill in yet",
                       message: "After an analysis, every photograph without a date or a place gathers here, ready to be filled in many at a time.")
        } else {
            HSplitView {
                VStack(spacing: 0) {
                    toolbar
                    Divider()
                    TipBanner(id: "fill-select", icon: "rectangle.dashed",
                              text: "Drag across photos to select many at once. ⌘-click adds or removes one; ⇧-click selects a range.")
                        .padding(.horizontal, D.Space.m).padding(.top, D.Space.s)
                    if engine.fillRows.isEmpty {
                        EmptyState(icon: "checkmark.circle", title: "Nothing here",
                                   message: engine.fillFilter == .entered ? "You have not filled in or accepted anything yet."
                                       : engine.fillFilter == .workedOut ? "No place is waiting to be accepted."
                                       : "Every photograph has a date and a place.")
                    } else {
                        grid
                    }
                }
                .frame(minWidth: 420)
                FillPanel(selected: selected.intersection(Set(engine.fillRows.map(\.id))),
                          rows: engine.fillRows.filter { selected.contains($0.id) },
                          clearSelection: { selected.removeAll(); anchor = nil })
                    .frame(minWidth: 290, idealWidth: 310, maxWidth: 360)
            }
            .onAppear { engine.loadFill() }
            .onChange(of: engine.fillFilter) { _, _ in selected.removeAll(); anchor = nil; engine.loadFill() }
        }
    }

    // MARK: toolbar

    private var toolbar: some View {
        HStack(spacing: D.Space.m) {
            Picker("", selection: $engine.fillFilter) {
                ForEach(Manual.Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().fixedSize()
            Text("\(engine.fillRows.count) shown" + (selected.isEmpty ? "" : " · \(selected.count) selected"))
                .font(.system(size: 15).monospacedDigit()).foregroundStyle(.secondary)
                .lineLimit(1).fixedSize()
            Spacer(minLength: D.Space.s)
            // no ⌘A here: it would take ⌘A away from the coordinate field
            Button("Select all") { selected = Set(engine.fillRows.map(\.id)) }
                .disabled(engine.fillRows.isEmpty).fixedSize()
            Button("Select none") { selected.removeAll(); anchor = nil }
                .disabled(selected.isEmpty).fixedSize()
            Image(systemName: "photo").font(.system(size: 15)).foregroundStyle(.tertiary)
            Slider(value: $side, in: 64...200).frame(width: 70)
            Image(systemName: "photo").font(.system(size: 20)).foregroundStyle(.tertiary)
        }
        .controlSize(.regular)
        .padding(.horizontal, D.Space.m).padding(.vertical, D.Space.s)
    }

    // MARK: grid

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: side, maximum: side + 40), spacing: 10)],
                      alignment: .leading, spacing: 12) {
                ForEach(Array(engine.fillRows.enumerated()), id: \.element.id) { i, row in
                    FillCell(row: row, side: side, selected: selected.contains(row.id))
                        .background(GeometryReader { g in
                            Color.clear.preference(key: CellFrames.self, value: [row.id: g.frame(in: .named("fillgrid"))])
                        })
                        .contentShape(Rectangle())
                        .onTapGesture { click(row.id, index: i) }
                }
            }
            .padding(D.Space.m)
            .coordinateSpace(name: "fillgrid")
            .onPreferenceChange(CellFrames.self) { frames.merge($0) { $1 } }
            .overlay(alignment: .topLeading) {
                if let band {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.12))
                        .overlay(Rectangle().strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1))
                        .frame(width: band.width, height: band.height)
                        .offset(x: band.minX, y: band.minY)
                        .allowsHitTesting(false)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .named("fillgrid"))
                    .onChanged { v in
                        if band == nil {
                            let mods = NSEvent.modifierFlags
                            bandBase = mods.contains(.command) || mods.contains(.shift) ? selected : []
                        }
                        let r = CGRect(x: min(v.startLocation.x, v.location.x), y: min(v.startLocation.y, v.location.y),
                                       width: abs(v.location.x - v.startLocation.x), height: abs(v.location.y - v.startLocation.y))
                        band = r
                        selected = bandBase.union(frames.filter { $0.value.intersects(r) }.map(\.key))
                    }
                    .onEnded { _ in band = nil }
            )
        }
    }

    private func click(_ id: Int, index: Int) {
        let mods = NSEvent.modifierFlags
        (selected, anchor) = Manual.click(selected, anchor: anchor, order: engine.fillRows.map(\.id), id: id,
                                          command: mods.contains(.command), shift: mods.contains(.shift))
    }
}

private struct CellFrames: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct FillCell: View {
    let row: Manual.Row
    let side: CGFloat
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Thumb(path: row.path, side: side)
                .overlay(
                    RoundedRectangle(cornerRadius: side > 60 ? D.Radius.card : D.Radius.small)
                        .strokeBorder(Color.accentColor, lineWidth: selected ? 3 : 0)
                )
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 27)).symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(5)
                    }
                }
            HStack(spacing: 4) {
                if row.needsDate { Image(systemName: "calendar.badge.exclamationmark").foregroundStyle(D.attention) }
                if row.needsPlace { Image(systemName: "mappin.slash").foregroundStyle(D.attention) }
                if row.workedOut { Image(systemName: "wand.and.stars").foregroundStyle(D.attention) }
                if row.entered { Image(systemName: "pencil").foregroundStyle(D.keep) }
                Text(caption).lineLimit(1).truncationMode(.tail)
            }
            .font(.system(size: 18)).foregroundStyle(.secondary)
            .frame(width: side, alignment: .leading)
        }
        .opacity(selected ? 1 : 0.92)
    }

    private var caption: String {
        if row.workedOut, let la = row.lat, let lo = row.lon { return placeLabel(la, lo) }
        guard let t = row.localTime else { return "no date" }
        let d = String(pretty(t).split(separator: ",").first ?? "")
        return row.needsDate ? "file date \(d)" : d
    }
}

/// The batch editor: what is selected, and what to give it.
struct FillPanel: View {
    @EnvironmentObject var engine: Engine
    let selected: Set<Int>
    let rows: [Manual.Row]
    let clearSelection: () -> Void

    @State private var setDay = true
    @State private var day = Date()
    @State private var setPlace = true
    @State private var placeText = ""

    @State private var picked: Gazetteer.Place?
    /// Coordinates typed, or a place chosen from the suggestions.
    private var parsed: (lat: Double, lon: Double)? {
        if let p = picked, placeText == p.fullLabel { return (p.lat, p.lon) }
        return Manual.coordinate(placeText)
    }
    private var suggestions: [Gazetteer.Place] {
        guard Manual.coordinate(placeText) == nil, picked?.fullLabel != placeText else { return [] }
        return Gazetteer.search(placeText, limit: 6)
    }
    private var placeReady: Bool { !setPlace || parsed != nil }
    private var anything: Bool { (setDay || setPlace) && placeReady && !selected.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: D.Space.l) {
                header
                if selected.isEmpty {
                    Text("Select photographs on the left — click, ⌘-click, ⇧-click, or drag a box across them. Then give them all a day, a place, or both.")
                        .font(.system(size: 18)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    dateCard
                    placeCard
                    Button {
                        engine.fill(Array(selected), day: setDay ? day : nil, place: setPlace ? parsed : nil)
                        clearSelection()
                    } label: {
                        Label("Apply to \(selected.count) photograph\(selected.count == 1 ? "" : "s")",
                              systemImage: "square.and.pencil")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bigProminent).controlSize(.extraLarge)
                    .disabled(!anything || engine.progress.running)

                    if rows.contains(where: \.workedOut) {
                        Button("Accept the worked-out place\(rows.filter(\.workedOut).count == 1 ? "" : "s") as \(rows.filter(\.workedOut).count == 1 ? "it is" : "they are")") {
                            engine.confirmPlaces(rows.filter(\.workedOut)); clearSelection()
                        }
                        .controlSize(.regular).disabled(engine.progress.running)
                    }
                    if rows.contains(where: \.entered) {
                        HStack {
                            Text("Clear what you entered:").font(.system(size: 15)).foregroundStyle(.secondary)
                            Button("Day") { engine.clearFill(Array(selected), day: true, place: false) }
                            Button("Place") { engine.clearFill(Array(selected), day: false, place: true) }
                        }
                        .controlSize(.regular).disabled(engine.progress.running)
                    }
                    Text("A date or GPS a file records is never replaced; a place the app worked out is. Nothing on disk changes — a clean library writes these into its files.")
                        .font(.system(size: 15)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(D.Space.l)
        }
        .onAppear { if let r = engine.recentPlaces.first { placeText = String(format: "%.5f, %.5f", r.lat, r.lon) } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(selected.isEmpty ? "Nothing selected" : "\(selected.count) selected")
                .font(.system(size: 26, weight: .semibold))
            if !selected.isEmpty {
                let nd = rows.filter(\.needsDate).count, np = rows.filter(\.needsPlace).count, nw = rows.filter(\.workedOut).count
                Text([nd > 0 ? "\(nd) without a date" : nil, np > 0 ? "\(np) without a place" : nil,
                      nw > 0 ? "\(nw) with a place worked out" : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 15)).foregroundStyle(.secondary)
                HStack(spacing: 3) {
                    ForEach(rows.prefix(6)) { Thumb(path: $0.path, side: 34) }
                    if rows.count > 6 { Text("+\(rows.count - 6)").font(.system(size: 15)).foregroundStyle(.tertiary) }
                }
                .padding(.top, 2)
            }
        }
    }

    private var dateCard: some View {
        Card {
            VStack(alignment: .leading, spacing: D.Space.s) {
                Toggle(isOn: $setDay) { Text("Day").font(.system(size: 22, weight: .semibold)) }
                    .toggleStyle(.checkbox)
                if setDay {
                    DatePicker("", selection: $day, in: ...Date(), displayedComponents: .date)
                        .datePickerStyle(.graphical).labelsHidden()
                        .frame(maxWidth: 260)
                    Text("To the day. The time of day stays unknown; a merged copy writes it as noon.")
                        .font(.system(size: 15)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var placeCard: some View {
        Card {
            VStack(alignment: .leading, spacing: D.Space.s) {
                Toggle(isOn: $setPlace) { Text("Place").font(.system(size: 22, weight: .semibold)) }
                    .toggleStyle(.checkbox)
                if setPlace {
                    TextField("a city — or latitude, longitude", text: $placeText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 21, design: .monospaced))
                    if placeText.isEmpty {
                        Text("Type a city (\"Lisbon\", \"東京\"), or coordinates such as 39.9042, 116.4074 — a map app's copied coordinates work.")
                            .font(.system(size: 15)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let p = parsed {
                        Label(placeLabel(p.lat, p.lon) + "  ·  " + prettyPlace(p.lat, p.lon), systemImage: "checkmark.circle.fill")
                            .font(.system(size: 15).monospacedDigit()).foregroundStyle(D.keep)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if !suggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(suggestions.enumerated()), id: \.offset) { _, p in
                                Button { picked = p; placeText = p.fullLabel } label: {
                                    HStack {
                                        Image(systemName: "mappin").foregroundStyle(.secondary)
                                        Text(p.fullLabel).lineLimit(1)
                                        Spacer()
                                        if !p.local.isEmpty { Text(p.local[0]).foregroundStyle(.tertiary) }
                                    }
                                    .font(.system(size: 15)).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .padding(.vertical, 2)
                            }
                        }
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: D.Radius.small).fill(.quinary))
                    } else {
                        Label("No such place or coordinate. Cities of 15,000+ people are listed; otherwise use latitude, longitude.", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 15)).foregroundStyle(D.attention)
                    }
                    if !engine.recentPlaces.isEmpty {
                        Text("Recently used").font(.system(size: 15).weight(.medium)).foregroundStyle(.secondary)
                        ForEach(Array(engine.recentPlaces.enumerated()), id: \.offset) { _, r in
                            Button {
                                placeText = String(format: "%.5f, %.5f", r.lat, r.lon)
                            } label: {
                                Text("\(placeLabel(r.lat, r.lon))  ·  \(r.uses) photo\(r.uses == 1 ? "" : "s")")
                                    .font(.system(size: 15).monospacedDigit())
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
