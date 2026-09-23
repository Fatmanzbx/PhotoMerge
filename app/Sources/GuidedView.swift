import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The default window: one flow, four steps across the top. Add photos →
/// Duplicates → Time & place → Save. Duplicates and Time & place can be taken in
/// either order and revisited as often as needed; Save opens once every photo has
/// a date and a place, or the person has chosen to leave the rest as they are.
/// Every pane is also under View → Advanced Tools.
struct GuidedView: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        VStack(spacing: 0) {
            StepBar()
            Divider()
            Group {
                switch engine.step {
                case .add:        AddStep()
                case .duplicates: DuplicatesStep()
                case .places:     PlacesStep()
                case .save:       SaveStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(D.canvas)
            Divider()
            StatusBar()
        }
        .sheet(item: $engine.sheet) { s in SheetHost(sheet: s) }
    }
}

// MARK: - step bar

struct StepBar: View {
    @EnvironmentObject var engine: Engine

    private func done(_ s: Guide.Step) -> Bool {
        switch s {
        case .add:        return engine.stats.assets > 0
        case .duplicates: return engine.stats.assets > 0 && engine.undecidedEdits == 0
        case .places:     return engine.stats.assets > 0 && engine.missingSettled
                              && engine.audit.isEmpty && engine.ballots.isEmpty
        case .save:       return engine.writtenCount > 0 || engine.tidied > 0
        }
    }
    private func reachable(_ s: Guide.Step) -> Bool {
        switch s {
        case .add:  return true
        case .save: return engine.stats.assets > 0 && engine.missingSettled
        default:    return engine.stats.assets > 0
        }
    }
    /// What still needs the person on that step.
    private func pending(_ s: Guide.Step) -> Int {
        guard engine.stats.assets > 0 else { return 0 }
        switch s {
        case .duplicates: return engine.undecidedEdits
        case .places:     return engine.audit.count + engine.ballots.count + (engine.missingSettled ? 0 : engine.missing.either)
        default:          return 0
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Guide.Step.allCases) { s in
                if s != .add {
                    Capsule().fill(done(Guide.Step(rawValue: s.rawValue - 1)!) ? AnyShapeStyle(D.keep.opacity(0.45)) : AnyShapeStyle(Color.primary.opacity(0.08)))
                        .frame(height: 3).frame(maxWidth: 56)
                }
                let current = engine.step == s
                Button { withAnimation(.easeOut(duration: 0.2)) { engine.step = s } } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            if current {
                                Circle().fill(D.accentGradient)
                                    .shadow(color: Color.accentColor.opacity(0.35), radius: 6, y: 2)
                            } else if done(s) {
                                Circle().fill(D.keep)
                            } else {
                                Circle().fill(D.surface)
                                    .overlay(Circle().strokeBorder(D.hairline, lineWidth: 1))
                            }
                            if done(s) && !current {
                                Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                            } else {
                                Text("\(s.rawValue + 1)").font(.system(size: 15, weight: .bold, design: .rounded))
                                    .foregroundStyle(current ? .white : .secondary)
                            }
                        }
                        .frame(width: 30, height: 30)
                        Text(s.title)
                            .font(.system(size: 19, weight: current ? .semibold : .regular))
                            .foregroundStyle(current ? .primary : .secondary)
                        if pending(s) > 0 {
                            Badge(text: pending(s).formatted(), color: D.attention)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background {
                        if current { Capsule().fill(Color.accentColor.opacity(0.08)) }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!reachable(s))
                .help(s == .save && !reachable(s) && engine.stats.assets > 0
                      ? "Give every photo a date and a place first — or, on Time & place, choose to leave the rest as they are."
                      : "")
            }
        }
        .padding(.vertical, D.Space.m)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .trailing) {
            Button { engine.advanced = true } label: {
                Label("All panes", systemImage: "sidebar.left").font(.system(size: 15))
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .help("Every pane and setting, with a sidebar (⌥⌘A). The same app, nothing tucked away.")
            .padding(.trailing, D.Space.l)
        }
        .background(.bar)
    }
}

/// The bar along the bottom of a step: where things stand, and the way on.
struct StepFooter<Actions: View>: View {
    var note: String? = nil
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: D.Space.m) {
            if let note {
                Text(note).font(.system(size: 18)).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            actions
        }
        .padding(.horizontal, 24).padding(.vertical, D.Space.m)
        .background(.bar)
        .overlay(alignment: .top) { D.hairline.frame(height: 1) }
    }
}

/// A step's title and one or two lines under it.
struct StepHeading: View {
    let title: String, detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: D.Space.xs) {
            Text(title).font(.system(size: 33, weight: .semibold))
            Text(detail).font(.system(size: 18)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 1. add

struct AddStep: View {
    @EnvironmentObject var engine: Engine
    @State private var targeted = false

    private var photosLibrary: URL? {
        let u = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/Photos Library.photoslibrary/originals")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
    /// Folders that could not be found, files that could not be opened.
    private var troubles: [Guide.Card] { engine.openCards.filter { $0.kind == .unavailable || $0.kind == .unreadable } }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: D.Space.l) {
                    StepHeading(title: "Add the photos you want to tidy",
                                detail: "Folders, drives, a Google Takeout, your Photos library — as many as you like. PhotoMerge only reads them; nothing is changed until you save, and everything can be undone.")
                    dropZone
                    ForEach(troubles) { TroubleCard(card: $0) }
                    if !engine.sourceInfo.isEmpty {
                        SectionLabel(text: "Added")
                        ForEach(engine.sourceInfo) { SourceCard(info: $0) }
                    }
                }
                .padding(24)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            Divider()
            StepFooter(note: footerNote) {
                // Reading starts when a folder is added; a folder added but never read
                // (added in Advanced, or reading stopped) needs a way to start it here.
                if !engine.sources.isEmpty && !engine.progress.running
                    && (engine.stats.files == 0 || engine.sourceInfo.contains { $0.unread > 0 }) {
                    Button { engine.analyse() } label: {
                        Label(engine.stats.files == 0 ? "Read them" : "Read the rest", systemImage: "sparkle.magnifyingglass")
                    }
                    .buttonStyle(.bigProminent).controlSize(.extraLarge)
                }
                if engine.stats.assets > 0 {
                    Button { engine.step = .duplicates } label: {
                        Label("Continue to Duplicates", systemImage: "arrow.right")
                    }
                    .buttonStyle(.bigProminent).controlSize(.extraLarge)
                    .disabled(engine.progress.running)
                }
            }
        }
    }

    private var footerNote: String? {
        let s = engine.stats
        if engine.progress.running { return "Reading — results fill in as it goes; you can go on to the next step meanwhile." }
        guard s.assets > 0 else { return engine.sources.isEmpty ? nil : "Nothing read yet." }
        return "\(s.assets.formatted()) photo\(s.assets == 1 ? "" : "s") in \(s.files.formatted()) file\(s.files == 1 ? "" : "s")"
            + (s.duplicates > 0 ? " · \(s.duplicates.formatted()) duplicate cop\(s.duplicates == 1 ? "y" : "ies")" : "")
    }

    private var dropZone: some View {
        VStack(spacing: D.Space.m) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 54, weight: .light))
                .foregroundStyle(targeted ? Color.accentColor : .secondary)
            Text(targeted ? "Drop to add" : "Drag folders here").font(.system(size: 26, weight: .medium))
            HStack(spacing: D.Space.m) {
                Button("Choose folders…") { pick() }
                if let lib = photosLibrary, !engine.sources.contains(lib.path) {
                    Button("Add my Photos library") { engine.addSource(lib); engine.analyse() }
                }
            }
            .disabled(engine.progress.running)
        }
        .frame(maxWidth: .infinity, minHeight: 190)
        .background(RoundedRectangle(cornerRadius: D.Radius.card)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
            .foregroundStyle(targeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.18))))
        .background(RoundedRectangle(cornerRadius: D.Radius.card).fill(targeted ? Color.accentColor.opacity(0.06) : D.surface.opacity(0.6)))
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            var urls: [URL] = []
            let group = DispatchGroup()
            for p in providers {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { u, _ in
                    if let u, (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { urls.append(u) }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                guard !urls.isEmpty else { return }
                urls.forEach(engine.addSource)
                engine.analyse()
            }
            return true
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = true; panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Add"
        panel.message = "Choose folders to tidy. They are only read, never changed."
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            panel.urls.forEach(engine.addSource)
            engine.analyse()
        }
    }
}

/// A folder that cannot be found, or files that would not open.
struct TroubleCard: View {
    @EnvironmentObject var engine: Engine
    let card: Guide.Card

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: D.Space.m) {
                Image(systemName: card.kind == .unavailable ? "externaldrive.badge.xmark" : "exclamationmark.triangle")
                    .font(.system(size: 36)).foregroundStyle(card.kind == .unavailable ? D.attention : .secondary)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 6) {
                    Text(card.title).font(.system(size: 26, weight: .semibold))
                    Text(card.detail).font(.system(size: 18)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button("OK") { engine.acknowledge(card) }
            }
        }
    }
}

// MARK: - 2. duplicates

struct DuplicatesStep: View {
    @EnvironmentObject var engine: Engine
    @State private var showSetting = false

    var body: some View {
        let s = engine.stats
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: D.Space.s) {
                HStack(alignment: .firstTextBaseline) {
                    StepHeading(title: title, detail: detail)
                    Spacer()
                    Button { withAnimation(.easeInOut(duration: 0.15)) { showSetting.toggle() } } label: {
                        Label(showSetting ? "Hide setting" : "How alike is a duplicate?", systemImage: "slider.horizontal.3")
                    }
                    .help("How similar two photos must look before they are compared pixel by pixel. Each setting is tried on your photos before you apply it.")
                }
                if showSetting {
                    ScrollView { MatchingDial(showLabel: false).padding(.top, D.Space.s) }
                        .frame(maxHeight: 380)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            GroupsView().frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            StepFooter(note: footerNote) {
                if engine.undecidedEdits > 0 {
                    Button("Keep them all as separate photos") { engine.keepAllSeparate() }
                        .disabled(engine.progress.running)
                        .help("Say “different” to every edited copy still undecided. ⌘Z undoes it.")
                }
                Button { engine.step = .places } label: {
                    Label("Continue to Time & place", systemImage: "arrow.right")
                }
                .buttonStyle(.bigProminent).controlSize(.extraLarge)
            }
        }
        .id(s.assets)  // a fresh analysis starts the step afresh
    }

    private var title: String {
        let s = engine.stats
        if s.duplicates > 0 {
            return "\(s.duplicates.formatted()) duplicate cop\(s.duplicates == 1 ? "y" : "ies") · \(byteString(s.wastedBytes)) recoverable"
        }
        return engine.progress.running ? "Looking for duplicates…" : "No duplicate copies found"
    }
    private var detail: String {
        "The best copy of each photo is kept — the most pixels, then the largest file — and it takes its date, time zone and place from all its copies together, so nothing known about a photo is lost with the extras. Nothing is removed until you save. Open a group to see why, or to keep a different copy."
            + (engine.undecidedEdits > 0 ? " Look-alikes the app would not decide on its own are under Edited copies." : "")
    }
    private var footerNote: String? {
        let n = engine.undecidedEdits
        if n > 0 { return "\(n) edited cop\(n == 1 ? "y" : "ies") — one shot, edited — need\(n == 1 ? "s" : "") your say: the same photo, or two?" }
        if engine.stats.duplicates > 0 { return "Extra copies are left out of a clean library, or moved to the Trash by Tidy." }
        return nil
    }
}

// MARK: - 3. time & place

struct PlacesStep: View {
    @EnvironmentObject var engine: Engine
    @State private var mode: Mode = .auto
    enum Mode { case auto, manual }

    /// Anything the automatic side still needs the person for: contradictions,
    /// unclear days, and places worked out but not yet accepted.
    private var autoOpen: Int { engine.audit.count + engine.ballots.count + engine.workedOutPlaces }

    var body: some View {
        let s = engine.stats
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: D.Space.m) {
                StepHeading(title: title, detail: detail)
                Segments(selection: $mode, items: [
                    (Mode.auto, autoOpen > 0 ? "Worked out for you  (\(autoOpen.formatted()))" : "Worked out for you"),
                    (Mode.manual, engine.missing.either > 0 ? "Fill in by hand  (\(engine.missing.either.formatted()))" : "Fill in by hand")])
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            Group {
                switch mode {
                case .auto:   AutoPlaces(fixByHand: { engine.fillFilter = .workedOut; mode = .manual })
                case .manual: FillView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            StepFooter(note: footerNote) {
                if engine.missing.either > 0 {
                    if engine.missingSettled {
                        Button("Look again") { engine.lookAgainAtMissing() }
                    } else {
                        Button("Leave the rest as they are") { engine.skipMissing() }
                            .disabled(engine.progress.running)
                            .help("Go on without a date or place for these. A clean library keeps them under Undated, with their file names. ⌘Z undoes this.")
                    }
                }
                Button { engine.step = .save } label: {
                    Label("Continue to Save", systemImage: "arrow.right")
                }
                .buttonStyle(.bigProminent).controlSize(.extraLarge)
                .disabled(!engine.missingSettled)
            }
        }
        // Nothing automatic left to decide but photos still missing: open on the grid.
        .onAppear { if autoOpen == 0 && engine.missing.either > 0 && !engine.missingSettled { mode = .manual } }
        .id(s.assets)
    }

    private var title: String {
        let m = engine.missing
        if m.either == 0 { return "Every photo has a date and a place" }
        return "\(m.either.formatted()) photo\(m.either == 1 ? "" : "s") still need\(m.either == 1 ? "s" : "") a date or a place"
    }
    private var detail: String {
        let s = engine.stats
        return "\(s.dated.formatted()) of \(s.assets.formatted()) dated"
            + (s.guessedTime > 0 ? " (\(s.guessedTime.formatted()) from the file's date only)" : "")
            + " · \(s.zoned.formatted()) with a time zone · \(s.located.formatted()) placed. "
            + "Dates, time zones and places are worked out from each photo, its copies and its neighbours in time. What cannot be known that way you can fill in by hand — many at once — or leave as it is. Nothing here changes your files; a clean library carries it."
    }
    private var footerNote: String? {
        let m = engine.missing
        guard m.either > 0 else { return autoOpen > 0 ? "\(autoOpen) thing\(autoOpen == 1 ? "" : "s") under Worked out for you would like your say — or carry on." : nil }
        let parts = [m.date > 0 ? "\(m.date.formatted()) without a date" : nil,
                     m.place > 0 ? "\(m.place.formatted()) without a place" : nil].compactMap { $0 }.joined(separator: ", ")
        return engine.missingSettled ? "Left as they are: \(parts)." : parts + "."
    }
}

/// What the app worked out on its own, and the few things it puts to you: times
/// that contradict their place, days whose time zone the evidence cannot settle,
/// and how far a photo without GPS may borrow a place.
struct AutoPlaces: View {
    @EnvironmentObject var engine: Engine
    var fixByHand: () -> Void = {}

    var body: some View {
        let s = engine.stats
        ScrollView {
            VStack(alignment: .leading, spacing: D.Space.l) {
                HStack(spacing: D.Space.m) {
                    CoverageCard(title: "Dated", have: s.dated, total: s.assets,
                                 note: s.guessedTime > 0 ? "\(s.guessedTime) from the file's timestamp only" : "all read from the photo")
                    CoverageCard(title: "Time zone", have: s.zoned, total: s.assets,
                                 note: "a date without a zone cannot be ordered against another zone")
                    CoverageCard(title: "Placed", have: s.located, total: s.assets,
                                 note: s.inferredPlace > 0 ? "\(s.inferredPlace) worked out from the same day" : "all measured")
                }
                if engine.progress.running {
                    Label("Still reading — these fill in as it goes.", systemImage: "hourglass")
                        .font(.system(size: 18)).foregroundStyle(.secondary)
                }
                if !engine.placeGroups.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        SectionLabel(text: "Places worked out, by area")
                        Badge(text: "\(engine.workedOutPlaces.formatted()) PHOTOS · \(engine.placeGroups.count) AREAS", color: D.attention)
                    }
                    Text("These photos carry no GPS; their place was taken from photos of the same day, a photo near in time, or the same folder. Look through each area: if some are wrong, give them their real place under Fill in by hand first — they leave the area — then accept the rest.")
                        .font(.system(size: 15)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(engine.placeGroups) { PlaceGroupCard(group: $0, fixByHand: fixByHand) }
                }
                if !engine.audit.isEmpty || engine.corrected > 0 { ChecksSection() }
                if !engine.ballots.isEmpty { BallotsSection() }
                if engine.audit.isEmpty && engine.ballots.isEmpty && engine.placeGroups.isEmpty && !engine.progress.running {
                    Card {
                        HStack(spacing: D.Space.m) {
                            Image(systemName: "checkmark.seal.fill").font(.system(size: 33)).foregroundStyle(D.keep)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Nothing here needs you").font(.system(size: 24, weight: .semibold))
                                Text(engine.missing.either > 0
                                     ? "No time contradicts its place and no day's zone is in doubt. What is still missing, nothing in the photos can tell — fill it in by hand, or leave it."
                                     : "No time contradicts its place, no day's zone is in doubt, and every photo has a date and a place.")
                                    .font(.system(size: 18)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                        }
                    }
                }
                SectionLabel(text: "How far a photo without GPS may borrow a place")
                PlaceDials(showLabel: false)
            }
            .padding(24)
            .frame(maxWidth: 1150, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

/// One area's worked-out places: every photo, so the odd one out can be spotted.
struct PlaceGroupCard: View {
    @EnvironmentObject var engine: Engine
    let group: Engine.PlaceGroup
    let fixByHand: () -> Void
    @State private var showAll = false
    private let shown = 48

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: D.Space.m) {
                HStack(alignment: .firstTextBaseline, spacing: D.Space.s) {
                    Image(systemName: "mappin.and.ellipse").foregroundStyle(D.attention)
                    Text(group.label).font(.system(size: 26, weight: .semibold))
                    Text("\(group.rows.count) photo\(group.rows.count == 1 ? "" : "s") · \(group.span)")
                        .font(.system(size: 18)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Fix some by hand", action: fixByHand)
                        .help("Open the grid of worked-out places: select the wrong ones and give them their real place. They leave this area.")
                    Button("Accept all \(group.rows.count)") { engine.confirmPlaces(group.rows) }
                        .buttonStyle(.bigProminent)
                        .disabled(engine.progress.running)
                }
                Text(group.how + " · " + prettyPlace(group.lat, group.lon))
                    .font(.system(size: 15)).foregroundStyle(.tertiary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84, maximum: 96), spacing: 8)], alignment: .leading, spacing: 10) {
                    ForEach(showAll ? group.rows : Array(group.rows.prefix(shown))) { r in
                        VStack(alignment: .leading, spacing: 3) {
                            Thumb(path: r.path, side: 84)
                            Text(r.localTime.map { pretty($0).components(separatedBy: ",")[0] } ?? "no date")
                                .font(.system(size: 16)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .onTapGesture { engine.inspect(r.id) }
                        .help("Why this place? Open in Decisions")
                    }
                }
                if group.rows.count > shown {
                    Button(showAll ? "Show fewer" : "Show all \(group.rows.count)") { showAll.toggle() }
                        .buttonStyle(.link).font(.system(size: 15))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - 4. save

struct SaveStep: View {
    @EnvironmentObject var engine: Engine
    @State private var choice: Choice? = nil
    enum Choice { case copy, tidy }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: D.Space.l) {
                StepHeading(title: "Save the result", detail: summary)
                HStack(alignment: .top, spacing: D.Space.m) {
                    option(.copy, icon: "square.and.arrow.down.on.square", title: "Save a clean library",
                           text: "A new folder with one file per photo — duplicates left out, dates, time zones and places written in. Your originals stay exactly as they are.")
                    option(.tidy, icon: "trash", title: "Tidy in place",
                           text: "Move the extra copies to the Trash, where you can put them back. Nothing else changes.")
                }
                switch choice {
                case .copy: WriteView().frame(minHeight: 620)
                case .tidy: TidyView()
                case nil: EmptyView()
                }
            }
            .padding(24)
            .frame(maxWidth: 1150, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { if choice == nil, engine.writtenCount > 0 { choice = .copy } }
    }

    private var summary: String {
        let s = engine.stats, m = engine.missing
        var t = "\(s.assets.formatted()) photo\(s.assets == 1 ? "" : "s")"
        if s.duplicates > 0 { t += ", \(s.duplicates.formatted()) extra cop\(s.duplicates == 1 ? "y" : "ies") to leave out" }
        t += " · \(s.pctDated)% dated · \(s.pctLocated)% placed."
        if m.either > 0 { t += " \(m.either.formatted()) left without a date or place go under Undated, keeping their names." }
        return t
    }

    private func option(_ c: Choice, icon: String, title: String, text: String) -> some View {
        Button { choice = c } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: icon).font(.system(size: 36)).foregroundStyle(Color.accentColor)
                    .frame(height: 30, alignment: .bottomLeading)
                Text(title).font(.system(size: 24, weight: .semibold)).foregroundStyle(.primary)
                Text(text).font(.system(size: 18)).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(D.Space.xl)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: D.Radius.card).fill(D.surface))
            .overlay(RoundedRectangle(cornerRadius: D.Radius.card)
                .strokeBorder(choice == c ? Color.accentColor : D.hairline, lineWidth: choice == c ? 2 : 1))
            .shadow(color: .black.opacity(choice == c ? 0.10 : 0.05), radius: 8, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - sheets

struct SheetHost: View {
    @EnvironmentObject var engine: Engine
    let sheet: Engine.Sheet

    private var title: String {
        switch sheet {
        case .duplicates: return "Duplicate copies"
        case .edited:     return "Edited copies"
        case .wrongTime:  return "Photos showing the wrong time"
        case .unclearDay: return "Which time zone was this day?"
        case .missing:    return "Fill in dates and places"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 26, weight: .semibold))
                Spacer()
                Button("Done") { engine.sheet = nil }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, D.Space.l).padding(.vertical, D.Space.m)
            Divider()
            Group {
                switch sheet {
                case .duplicates: GroupsView()
                case .edited:     ReviewList()
                case .wrongTime:  ScrollView { ChecksSection().padding(20) }
                case .unclearDay: ScrollView { BallotsSection().padding(20) }
                case .missing:    FillView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1000, idealWidth: 1100, minHeight: 640, idealHeight: 760)
    }
}
