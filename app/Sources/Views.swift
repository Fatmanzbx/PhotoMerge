import SwiftUI
import AppKit
import ImageIO
import AVFoundation

// MARK: - sources

struct SourcesView: View {
    @EnvironmentObject var engine: Engine
    @State private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            if engine.sources.isEmpty {
                EmptyState(icon: "folder.badge.plus",
                           title: "Add the folders that hold your photographs",
                           message: "A Google Takeout, an old library, a folder of phone dumps — anything. PhotoMerge reads them and reports what it finds. It never moves, changes or deletes a file.") {
                    Button { pick() } label: {
                        Label("Choose folders…", systemImage: "plus")
                    }
                    .buttonStyle(.bigProminent)
                    .controlSize(.extraLarge)
                    .padding(.top, D.Space.xs)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: D.Space.s) {
                        if !engine.progress.running, engine.sourceInfo.contains(where: { $0.unread > 0 }) {
                            ResumeBanner(unread: engine.sourceInfo.reduce(0) { $0 + $1.unread })
                        }
                        SectionLabel(text: "\(engine.sources.count) source\(engine.sources.count == 1 ? "" : "s")")
                            .padding(.top, D.Space.s)
                        ForEach(engine.sourceInfo) { SourceCard(info: $0) }
                    }
                    .padding(20)
                }
            }
        }
        .confirmationDialog("Forget all \(engine.sources.count) source\(engine.sources.count == 1 ? "" : "s")?",
                            isPresented: $confirmClear) {
            Button("Forget all", role: .destructive) { engine.removeAll() }
        } message: {
            Text("Everything read from them is forgotten, and reading them again takes as long as the first time. Your folders and photos are not touched.")
        }
        .toolbar {
            ToolbarItemGroup {
                Button { pick() } label: { Label("Add folder", systemImage: "plus") }
                    .disabled(engine.progress.running)
                Button {
                    engine.analyse()
                } label: {
                    Label("Analyse", systemImage: "sparkle.magnifyingglass")
                }
                .buttonStyle(.bigProminent)
                .disabled(engine.sources.isEmpty || engine.progress.running)
                // One click used to forget a whole analysed library, without a word.
                Button(role: .destructive) { confirmClear = true } label: {
                    Label("Clear", systemImage: "trash")
                }
                .help("Forget every source and what was read from it. No folder is touched.")
                .disabled(engine.progress.running || engine.sources.isEmpty)
            }
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders to analyse. They are only read, never changed."
        if panel.runModal() == .OK { panel.urls.forEach(engine.addSource); engine.analyse() }
    }
}

struct ResumeBanner: View {
    @EnvironmentObject var engine: Engine
    let unread: Int
    var body: some View {
        HStack(spacing: D.Space.m) {
            Image(systemName: "pause.circle.fill").font(.system(size: 26)).foregroundStyle(D.attention)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(unread) file\(unread == 1 ? "" : "s") found but not read yet")
                    .font(.system(size: 22, weight: .semibold))
                Text("The last run stopped part-way. Everything read so far is kept; continuing reads only the rest.")
                    .font(.system(size: 15)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Continue") { engine.analyse() }.buttonStyle(.bigProminent)
        }
        .padding(D.Space.m)
        .background(D.attention.opacity(0.08), in: RoundedRectangle(cornerRadius: D.Radius.card))
    }
}

struct SourceCard: View {
    @EnvironmentObject var engine: Engine
    let info: Engine.SourceInfo
    @State private var confirmRemove = false
    @State private var editing = false
    @State private var draft = ""
    static let presets = ["Screenshots", "WhatsApp Images", "Thumbnails", "*.png", "*.gif", ".trashed-*"]

    var body: some View {
        Card {
          VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: D.Space.m) {
                Image(systemName: info.available ? "folder.fill" : "externaldrive.badge.xmark")
                    .font(.system(size: 22))
                    .foregroundStyle(info.available ? AnyShapeStyle(.tint) : AnyShapeStyle(D.attention))
                VStack(alignment: .leading, spacing: 4) {
                    Text((info.path as NSString).lastPathComponent)
                        .font(.system(size: 22, weight: .medium))
                    Text(info.path)
                        .font(.system(size: 15)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                    if !info.available {
                        Text("Not found — unplugged or moved. Its files are kept until it is back or removed.")
                            .font(.system(size: 15)).foregroundStyle(D.attention)
                    }
                    if info.files > 0 {
                        HStack(spacing: D.Space.m) {
                            fact(info.images.formatted(), "photos")
                            fact(info.videos.formatted(), "videos")
                            fact(byteString(info.bytes), "")
                            if let a = info.earliest, let b = info.latest {
                                fact(String(a.prefix(4)) + (a.prefix(4) == b.prefix(4) ? "" : "–" + b.prefix(4)), "")
                            }
                            if info.unread > 0 { fact(info.unread.formatted(), "not read yet", D.attention) }
                            if info.unreadable > 0 {
                                fact("\(info.unreadable)", "could not be opened", D.attention)
                                    .help("Permissions, or a file that vanished while being read. It is tried again if it changes.")
                            }
                            if info.unrecognised > 0 {
                                fact(info.unrecognised.formatted(), "not photos or videos the app reads", D.attention)
                                    .help("Left out: \(info.unrecognisedKinds). PhotoMerge reads JPEG, PNG, GIF, WebP, HEIC/AVIF, TIFF and TIFF-based RAW, and MP4/MOV video. AVI, MKV, WMV and other formats are not included in a clean library.")
                            }
                        }
                        .padding(.top, 2)
                    }
                }
                Spacer()
                Button(info.exclude.isEmpty ? "Exclude…" : "Exclusions (\(info.exclude.split(whereSeparator: \.isNewline).count))") {
                    draft = info.exclude; editing.toggle()
                }
                .buttonStyle(.link).font(.system(size: 15))
                .disabled(engine.progress.running)
                Button { if info.files > 0 { confirmRemove = true } else { engine.removeSource(info.id) } } label: {
                    Image(systemName: "minus.circle")
                }
                    .accessibilityLabel("Forget this source")
                    .buttonStyle(.borderless)
                    .help("Forget this source. The folder is not touched.")
                    .disabled(engine.progress.running)
                    .confirmationDialog("Forget \((info.path as NSString).lastPathComponent)?", isPresented: $confirmRemove) {
                        Button("Forget it", role: .destructive) { engine.removeSource(info.id) }
                    } message: {
                        Text("The \(info.files) files read from it are forgotten. The folder is not touched.")
                    }
            }
            if editing {
                VStack(alignment: .leading, spacing: D.Space.s) {
                    Divider()
                    Text("Leave out — one per line. A name skips that folder or file anywhere inside; a pattern with * matches names or paths.")
                        .font(.system(size: 15)).foregroundStyle(.secondary)
                    TextEditor(text: $draft)
                        .font(.system(size: 21, design: .monospaced))
                        .frame(height: 70)
                        .overlay(RoundedRectangle(cornerRadius: D.Radius.small).strokeBorder(.quaternary))
                    HStack(spacing: 6) {
                        ForEach(Self.presets, id: \.self) { p in
                            Button(p) {
                                let lines = draft.split(whereSeparator: \.isNewline).map(String.init)
                                if !lines.contains(p) { draft = (lines + [p]).joined(separator: "\n") }
                            }
                            .controlSize(.regular)
                        }
                        Spacer()
                        Button("Cancel") { editing = false }.controlSize(.regular)
                        Button("Save") { engine.setExclusions(info.id, draft); editing = false }
                            .controlSize(.regular).buttonStyle(.bigProminent)
                    }
                    Text("Takes effect on the next analysis (⌘R). Files already read that match are forgotten; nothing on disk is touched.")
                        .font(.system(size: 18)).foregroundStyle(.tertiary)
                }
                .padding(.top, D.Space.s)
            }
          }
        }
    }

    private func fact(_ v: String, _ label: String, _ tint: Color = .secondary) -> some View {
        HStack(spacing: 3) {
            Text(v).font(.system(size: 20, weight: .semibold)).monospacedDigit()
            if !label.isEmpty { Text(label).font(.system(size: 20)) }
        }
        .foregroundStyle(tint)
    }
}

// MARK: - duplicate groups

struct GroupsView: View {
    @EnvironmentObject var engine: Engine
    @State private var selected: Int?
    @State private var mode: Mode = .groups

    enum Mode: Hashable { case groups, review }

    private var undecided: Int { engine.reviewPairs.filter { !$0.decided }.count }

    var body: some View {
        if engine.groups.isEmpty && engine.reviewPairs.isEmpty {
            EmptyState(icon: engine.stats.files == 0 ? "questionmark.folder" : "checkmark.seal.fill",
                       title: engine.stats.files == 0 ? "Nothing analysed yet"
                                                      : "No duplicates found",
                       message: engine.stats.files == 0
                            ? "Add a folder and press Analyse."
                            : "All \(engine.stats.files) files are distinct at the current similarity setting. Widen the radius in Dials to look harder.")
        } else {
            VStack(spacing: 0) {
                if !engine.reviewPairs.isEmpty {
                    Segments(selection: $mode, items: [(Mode.groups, engine.groupsTotal > engine.groups.count
                                                            ? "Groups  \(engine.groups.count) of \(engine.groupsTotal.formatted())" : "Groups  \(engine.groups.count)"),
                                                       (Mode.review, undecided > 0 ? "Edited copies  \(undecided)" : "Edited copies ✓")])
                    .padding(.vertical, D.Space.s)
                    Divider()
                }
                if mode == .review && !engine.reviewPairs.isEmpty {
                    ReviewList()
                } else {
                    groups
                }
            }
            .onAppear { if undecided > 0 && engine.groups.isEmpty { mode = .review } }
        }
    }

    @ViewBuilder private var groups: some View {
        if engine.groups.isEmpty {
            EmptyState(icon: "checkmark.seal.fill", title: "No duplicates yet",
                       message: "Nothing was merged automatically. The pairs under Edited copies are ones the app would not decide on its own.")
        } else {
            HSplitView {
                List(selection: $selected) {
                    ForEach(engine.groups) { g in
                        GroupRow(group: g).tag(g.id)
                    }
                }
                .listStyle(.inset)
                .frame(minWidth: 296, idealWidth: 330, maxWidth: 420)

                if let id = selected, let g = engine.groups.first(where: { $0.id == id }) {
                    GroupDetail(group: g)
                } else {
                    EmptyState(icon: "sidebar.right",
                               title: "Select a group",
                               message: "Each group is one photograph the app believes it has more than one copy of. Open one to see why, and which copy it would keep.")
                }
            }
            // ←/→ move between groups without leaving the keyboard (PLAN §5)
            .onAppear { if selected == nil { selected = engine.groups.first?.id } }
            .focusable()
            .focusEffectDisabled()      // the ring outlined the whole pane, sidebar included
            .onMoveCommand { dir in
                guard let cur = selected,
                      let i = engine.groups.firstIndex(where: { $0.id == cur }) else { return }
                if dir == .down || dir == .right, i + 1 < engine.groups.count {
                    selected = engine.groups[i + 1].id
                } else if dir == .up || dir == .left, i > 0 {
                    selected = engine.groups[i - 1].id
                }
            }
        }
    }
}

/// The boundary cases: pairs that are clearly one frame but not identical — a
/// re-grade, a filter, an export with different colour. Whether that is "the same
/// photograph" is a matter of taste, so the app asks rather than guesses.
struct ReviewList: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: D.Space.l) {
                Text("These look like one shot, edited: the same instant and the same frame, but a different crop, colour or exposure. Whether an edit is the same photograph is your call — the app never merges these on its own.")
                    .font(.system(size: 18)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 640, alignment: .leading)
                ForEach(engine.reviewPairs) { ReviewCard(pair: $0) }
            }
            .padding(20)
        }
    }
}

struct ReviewCard: View {
    @EnvironmentObject var engine: Engine
    let pair: Engine.ReviewPair

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: D.Space.m) {
                HStack(alignment: .top, spacing: D.Space.l) {
                    side(pair.a)
                    side(pair.b)
                }
                Text(explanation)
                    .font(.system(size: 15)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: D.Space.s) {
                    if pair.decided {
                        Label(pair.outcome == .youSame ? "You said: the same photograph"
                                                       : "You said: different photographs",
                              systemImage: "checkmark.circle.fill")
                            .font(.system(size: 18).weight(.medium))
                            .foregroundStyle(D.keep)
                        Spacer()
                        Button("Undo") { engine.decide(pair, same: nil) }
                    } else {
                        Button { engine.decide(pair, same: true) } label: {
                            Label("Same photograph — keep one", systemImage: "square.on.square")
                        }
                        .buttonStyle(.bigProminent)
                        Button { engine.decide(pair, same: false) } label: {
                            Label("Different — keep both", systemImage: "square.split.2x1")
                        }
                        Spacer()
                    }
                }
                .disabled(engine.progress.running)
            }
        }
    }

    private func side(_ s: Engine.ReviewPair.Side) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Thumb(path: s.path, side: 200)
                .overlay(alignment: .topLeading) {
                    if !pair.decided || pair.outcome == .youSame, s.id == keeps.id {
                        Badge(text: pair.decided ? "KEPT" : "WOULD KEEP", color: D.keep)
                            .background(.regularMaterial, in: Capsule())
                            .padding(6)
                    }
                }
            Text((s.path as NSString).lastPathComponent)
                .font(.system(size: 20, weight: .medium)).lineLimit(1).truncationMode(.middle)
                .frame(width: 200, alignment: .leading)
            Text("\(s.w)×\(s.h) · \(byteString(s.bytes))")
                .font(.system(size: 18)).monospacedDigit().foregroundStyle(.secondary)
            if let t = s.capturedAt {
                Text(pretty(t)).font(.system(size: 18)).monospacedDigit().foregroundStyle(.tertiary)
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.path)])
            }
            .buttonStyle(.link).font(.system(size: 18))
        }
    }

    private var explanation: String {
        guard let hi = pair.maeHi, let lo = pair.maeLo else {
            return "You decided this pair by hand."
        }
        return String(format: "Taken at the same instant, and they differ evenly across the frame — %.1f on a 0–255 scale in the fine detail, %.1f in the broad shapes — the way an edit, a filter or a crop does. Two different photographs would differ more in the detail than in the shapes; two saves of one photograph would differ by under %.0f.",
                      hi, lo, Clusterer.confirmMAE)
    }

    /// The copy "same photograph" would keep: the rule the cascade uses everywhere —
    /// most pixels, then the larger file.
    private var keeps: Engine.ReviewPair.Side {
        let a = pair.a, b = pair.b
        if a.w * a.h != b.w * b.h { return a.w * a.h > b.w * b.h ? a : b }
        return a.bytes >= b.bytes ? a : b
    }
}

struct GroupRow: View {
    let group: Engine.Group

    var body: some View {
        HStack(spacing: D.Space.m) {
            Thumb(path: group.files.first?.path, side: 46)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: D.Space.s) {
                    Text("\(group.size) copies")
                        .font(.system(size: 22, weight: .medium))
                    Badge(text: methodLabel, color: .secondary)
                }
                HStack(spacing: D.Space.s) {
                    Text(byteString(group.wasted))
                        .font(.system(size: 15).weight(.medium))
                        .foregroundStyle(D.attention)
                    if let t = group.localTime {
                        Text(pretty(t)).font(.system(size: 15)).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    private var methodLabel: String {
        switch group.method {
        case "exact":          return "IDENTICAL"
        case "same image":     return "RE-ENCODED"
        case "same recording": return "VIDEO"
        case "chosen":         return "YOUR CALL"
        default:               return "SIMILAR"
        }
    }
}

struct GroupDetail: View {
    @EnvironmentObject var engine: Engine
    let group: Engine.Group
    @State private var compare = false

    /// "2 copies of one photograph" misled when the extra was not a photograph
    /// at all but a second copy of the Live Photo's clip, as Photos sometimes keeps.
    private var headline: String {
        let dups = group.files.filter { $0.role == "duplicate" }
        let clips = dups.filter { ($0.reason ?? "").contains("motion clip") }.count
        if clips > 0, clips == dups.count {
            return "One photograph, with \(clips == 1 ? "an extra copy" : "\(clips) extra copies") of its Live Photo clip"
        }
        return "\(group.size) copies of one \(group.method == "same recording" ? "recording" : "photograph")"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: D.Space.l) {
                // headline
                VStack(alignment: .leading, spacing: D.Space.xs) {
                    Text(headline)
                        .font(.system(size: 28, weight: .semibold))
                    Text("Keeping the copy marked **KEEP**. The rest are \(byteString(group.wasted)) of duplicate data.")
                        .font(.system(size: 18)).foregroundStyle(.secondary)
                }

                // what the resolver decided, and on what evidence
                Card {
                    VStack(alignment: .leading, spacing: D.Space.s) {
                        HStack {
                            SectionLabel(text: "What this photograph is")
                            Spacer()
                            Button("Why?") { engine.inspect(group.id) }
                                .buttonStyle(.link).font(.system(size: 15))
                        }
                        FactRow(label: "When",
                                value: group.localTime.map {
                                    pretty($0) + (group.utcOffset.map { " (\($0))" } ?? "")
                                } ?? "unknown",
                                source: [group.timeSource, group.zoneSource]
                                    .compactMap { $0 }.filter { $0 != "none" }
                                    .joined(separator: " · "))
                        FactRow(label: "Where",
                                value: group.lat.map { placeLabel($0, group.lon ?? 0) } ?? "unknown",
                                source: group.placeSource == "none" ? "" : (group.placeSource ?? ""))
                    }
                }

                TipBanner(id: "keep-keys", icon: "keyboard",
                          text: "Press 1–9 to keep a different copy, or space to compare them side by side.")
                // the copies
                HStack {
                    SectionLabel(text: "The copies")
                    Spacer()
                    Button { compare = true } label: { Label("Compare", systemImage: "rectangle.split.2x1") }
                        .controlSize(.regular)
                        .help("Side by side at the same size, or flip between them (space)")
                }
                ForEach(Array(group.files.enumerated()), id: \.element.id) { i, f in
                    CopyRow(file: f, group: group, index: i)
                }
            }
            .padding(20)
        }
        .sheet(isPresented: $compare) { CompareView(files: group.files.filter { $0.role != "companion" }) }
        // keyboard-first (PLAN §5): 1–9 keeps that copy, space compares
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) { compare = true; return .handled }
        .onKeyPress(characters: .decimalDigits) { press in
            guard let n = Int(press.characters), n >= 1 else { return .ignored }
            let copies = group.files.filter { $0.role != "companion" }
            guard n <= copies.count else { return .ignored }
            let f = copies[n - 1]
            engine.keep(f.role == "canonical" ? nil : f.id, in: group)
            return .handled
        }
    }
}

/// Two copies at the same size, side by side — or flipped in one frame, which is
/// how a difference in crop, colour or sharpness actually becomes visible.
struct CompareView: View {
    @Environment(\.dismiss) private var dismiss
    let files: [Engine.FileRow]
    @State private var a = 0
    @State private var b = 1
    @State private var flipped = false
    @State private var showB = false

    var body: some View {
        VStack(spacing: D.Space.m) {
            HStack {
                Segments(selection: $flipped, items: [(false, "Side by side"), (true, "Flip")])
                if flipped {
                    Text("Space or ←/→ flips between them")
                        .font(.system(size: 15)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if flipped {
                pane(showB ? b : a, big: true)
            } else {
                HStack(spacing: D.Space.m) { pane(a, big: false); pane(b, big: false) }
            }
        }
        .padding(20)
        .frame(minWidth: 900, minHeight: 620)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) { showB.toggle(); return .handled }
        .onKeyPress(.leftArrow) { showB = false; return .handled }
        .onKeyPress(.rightArrow) { showB = true; return .handled }
        .onAppear { b = min(1, files.count - 1) }
    }

    private func pane(_ i: Int, big: Bool) -> some View {
        let f = files[max(0, min(i, files.count - 1))]
        return VStack(alignment: .leading, spacing: D.Space.s) {
            LargeImage(path: f.path)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: D.Space.s) {
                if files.count > 2 {
                    Picker("", selection: i == a ? $a : $b) {
                        ForEach(Array(files.enumerated()), id: \.offset) { n, x in
                            Text("\(n + 1). \((x.path as NSString).lastPathComponent)").tag(n)
                        }
                    }
                    .labelsHidden().frame(maxWidth: 260)
                } else {
                    Text((f.path as NSString).lastPathComponent)
                        .font(.system(size: 21, weight: .medium)).lineLimit(1).truncationMode(.middle)
                }
                if f.role == "canonical" { Badge(text: "KEEP", color: D.keep) }
                Spacer()
                Text("\(f.w)×\(f.h) · \(byteString(f.bytes)) · \((f.path as NSString).pathExtension.uppercased())")
                    .font(.system(size: 15).monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}

/// A full-size image, fitted. Decoded at up to 2400 px so detail is comparable.
struct LargeImage: View {
    let path: String
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            Rectangle().fill(.quinary)
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                ProgressView().controlSize(.regular)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: D.Radius.card))
        .task(id: path) {
            image = nil
            image = await Thumbnails.image(path, side: 1200)
        }
    }
}

struct FactRow: View {
    let label: String, value: String, source: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: D.Space.s) {
            Text(label)
                .font(.system(size: 15).weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 66, alignment: .leading)
            Text(value)
                .font(.system(size: 22, design: .rounded)).monospacedDigit()
            if !source.isEmpty {
                SourcePill(text: source, inferred: isInferred(source))
            }
            Spacer(minLength: 0)
        }
    }
}

struct CopyRow: View {
    @EnvironmentObject var engine: Engine
    let file: Engine.FileRow
    var group: Engine.Group? = nil
    var index: Int? = nil
    @State private var hovering = false

    private var chosenByYou: Bool { file.reason == "kept: you chose this copy" }

    var body: some View {
        HStack(alignment: .top, spacing: D.Space.m) {
            Thumb(path: file.path, side: 104)
            VStack(alignment: .leading, spacing: D.Space.xs) {
                HStack(spacing: D.Space.s) {
                    if file.role == "canonical" {
                        Badge(text: chosenByYou ? "KEEP · YOUR CHOICE" : "KEEP", color: D.keep)
                    } else if file.role == "companion" {
                        Badge(text: "LIVE PHOTO CLIP", color: .blue)
                    } else {
                        Badge(text: "DUPLICATE", color: .secondary)
                    }
                    Text("\(file.w) × \(file.h)")
                        .font(.system(size: 15).monospacedDigit()).foregroundStyle(.secondary)
                    Text(byteString(file.bytes))
                        .font(.system(size: 15).monospacedDigit()).foregroundStyle(.secondary)
                }
                Text((file.path as NSString).lastPathComponent)
                    .font(.system(size: 21, weight: .medium))
                    .textSelection(.enabled)
                Text((file.path as NSString).deletingLastPathComponent)
                    .font(.system(size: 18)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.head)
                if let r = file.reason {
                    Text(r).font(.system(size: 15)).foregroundStyle(.secondary)
                }
                HStack(spacing: D.Space.m) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
                    } label: {
                        Label("Show in Finder", systemImage: "arrow.up.forward.app")
                            .font(.system(size: 15))
                    }
                    .buttonStyle(.link)
                    if let group, file.role == "duplicate" {
                        Button("Keep this copy instead") { engine.keep(file.id, in: group) }
                            .buttonStyle(.link).font(.system(size: 15))
                            .disabled(engine.progress.running)
                    }
                    if let group, file.role == "canonical", chosenByYou {
                        Button("Let the app choose") { engine.keep(nil, in: group) }
                            .buttonStyle(.link).font(.system(size: 15))
                            .disabled(engine.progress.running)
                    }
                }
                .padding(.top, 1)
            }
            Spacer(minLength: 0)
            if let index, index < 9, file.role != "companion" {
                Text("\(index + 1)")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, height: 18)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 4))
                    .help("Press \(index + 1) to keep this copy")
            }
        }
        .padding(D.Space.m)
        .background(hovering ? AnyShapeStyle(.quinary) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: D.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: D.Radius.card)
                .strokeBorder(file.role == "canonical"
                              ? AnyShapeStyle(D.keep.opacity(0.35))
                              : AnyShapeStyle(.quaternary),
                              lineWidth: file.role == "canonical" ? 1 : 0.5)
        )
        .onHover { hovering = $0 }
    }
}

// MARK: - dates & places

struct TimelineView: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        let s = engine.stats
        if s.assets == 0 {
            EmptyState(icon: "calendar.badge.clock",
                       title: "Nothing analysed yet",
                       message: "Once a folder has been analysed, this is where the dates and places end up — and how each one was arrived at.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: D.Space.l) {
                    SectionLabel(text: "Coverage")
                    HStack(spacing: D.Space.m) {
                        CoverageCard(title: "Dated", have: s.dated, total: s.assets,
                                     note: s.guessedTime > 0 ? "\(s.guessedTime) from the file's timestamp only" : "all read from the photograph")
                        CoverageCard(title: "Timezone", have: s.zoned, total: s.assets,
                                     note: "a date without a zone cannot be ordered against another zone")
                        CoverageCard(title: "Located", have: s.located, total: s.assets,
                                     note: s.inferredPlace > 0 ? "\(s.inferredPlace) inferred from the same day" : "all measured")
                    }

                    if engine.months.count > 1 {
                        SectionLabel(text: "Over time")
                        Card { TimelineChart(months: engine.months) }
                    }

                    if !engine.audit.isEmpty || engine.corrected > 0 {
                        ChecksSection()
                    }

                    if !engine.ballots.isEmpty { BallotsSection() }

                    if !engine.settled.isEmpty {
                        HStack(alignment: .firstTextBaseline) {
                            SectionLabel(text: "Settled by you")
                            Badge(text: engine.settled.count == 1 ? "1 DAY" : "\(engine.settled.count) DAYS",
                                  color: D.keep)
                            Spacer()
                        }
                        Card {
                            VStack(alignment: .leading, spacing: D.Space.s) {
                                ForEach(engine.settled) { s in
                                    HStack(spacing: D.Space.s) {
                                        Text(s.label).font(.system(size: 18))
                                        Text(s.offset)
                                            .font(.system(size: 21, design: .monospaced))
                                            .foregroundStyle(D.keep)
                                        Text("\(s.photographs) photograph\(s.photographs == 1 ? "" : "s")")
                                            .font(.system(size: 15)).foregroundStyle(.tertiary)
                                        Spacer()
                                        Button("Take it back") { engine.choose(day: s.day, offset: nil) }
                                            .controlSize(.regular)
                                    }
                                }
                            }
                        }
                        Text("Your choices live in PhotoMerge's own catalog. Your photographs are untouched either way.")
                            .font(.system(size: 15)).foregroundStyle(.secondary)
                    }

                    if !engine.placeRules.isEmpty {
                        SectionLabel(text: "Your place rules")
                        Card {
                            VStack(alignment: .leading, spacing: D.Space.s) {
                                ForEach(engine.placeRules, id: \.id) { rule in
                                    HStack {
                                        Image(systemName: "mappin.and.ellipse").foregroundStyle(D.keep)
                                        Text(rule.label).font(.system(size: 18))
                                        Text(placeLabel(rule.lat, rule.lon)).font(.system(size: 15)).foregroundStyle(.tertiary)
                                        Spacer()
                                        Button("Remove") { engine.deleteRule(rule.id) }
                                            .controlSize(.regular).disabled(engine.progress.running)
                                    }
                                }
                                Text("Used only for photographs no evidence could place. Add one from any located photograph in Decisions.")
                                    .font(.system(size: 15)).foregroundStyle(.secondary)
                            }
                        }
                    }

                    SectionLabel(text: "How places were decided")
                    Card {
                        VStack(alignment: .leading, spacing: D.Space.s) {
                            ForEach(engine.placeBreakdown, id: \.0) { row in
                                HStack {
                                    SourcePill(text: row.0, inferred: isInferred(row.0))
                                    Spacer()
                                    Text("\(row.1)").font(.system(size: 18).monospacedDigit())
                                }
                            }
                        }
                    }

                    Text("Anything not read straight off the photograph is shown in orange, here and everywhere else. A guess that looks like a measurement is worse than a gap.")
                        .font(.system(size: 15)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }
        }
    }
}

/// Contradictions in the result: photographs whose timezone disagrees with where
/// and when they were taken. The instant is kept; only the zone — and so the local
/// clock — would change, and only if you say so.
struct ChecksSection: View {
    @EnvironmentObject var engine: Engine
    @State private var open: String?

    private var groups: [(key: String, rows: [Engine.AuditRow])] {
        Dictionary(grouping: engine.audit, by: { "\($0.finding.offset) → \($0.finding.expected)" })
            .map { ($0.key, $0.value.sorted { $0.before < $1.before }) }
            .sorted { $0.rows.count > $1.rows.count }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: D.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: "Checks")
                if !engine.audit.isEmpty {
                    Badge(text: "\(engine.audit.count) CONTRADICTIONS", color: D.attention)
                }
                Spacer()
                if engine.corrected > 0 {
                    Text("\(engine.corrected) corrected by you").font(.system(size: 15)).foregroundStyle(D.keep)
                    Button("Undo corrections") { engine.undoCorrections() }
                        .controlSize(.regular).disabled(engine.progress.running)
                }
            }
            if !engine.audit.isEmpty {
                Text("These photographs record a time zone that cannot be right: the clocks where they were taken showed another, or the photographs around them say otherwise. Two things could be wrong, and only you know which. **Correct** treats the moment as right and moves the clock shown — for a photo whose time was converted under the wrong zone. **Keep the clock** treats the clock as right and moves the moment — for a camera that showed local time while the import stamped its home zone; the times you see stay as they are. Look at a few before pressing either for a whole group. Your files are not changed; a clean library carries the correction.")
                    .font(.system(size: 15)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(groups, id: \.key) { g in
                Card {
                    VStack(alignment: .leading, spacing: D.Space.s) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(g.key).font(.system(size: 22, weight: .semibold, design: .monospaced))
                            Text("\(g.rows.count) photograph\(g.rows.count == 1 ? "" : "s")")
                                .font(.system(size: 15)).foregroundStyle(.secondary)
                            Spacer()
                            Button("Keep the clock") { engine.correct(g.rows, keepClock: true) }
                                .disabled(engine.progress.running)
                                .help("The clock shown was right; only the zone was wrong. Sets \(g.rows[0].finding.expected) and leaves every time as it reads.")
                            Button("Correct \(g.rows.count == 1 ? "it" : "all \(g.rows.count)")") { engine.correct(g.rows) }
                                .buttonStyle(.bigProminent).controlSize(.regular)
                                .disabled(engine.progress.running)
                                .help("The moment was right; the clock shown was not. Moves each clock to \(g.rows[0].finding.expected).")
                        }
                        ForEach(g.rows.prefix(open == g.key ? g.rows.count : 2)) { AuditRowView(row: $0) }
                        if g.rows.count > 2 {
                            Button(open == g.key ? "Show fewer" : "Review all \(g.rows.count) one by one") {
                                open = open == g.key ? nil : g.key
                            }
                            .buttonStyle(.link).font(.system(size: 15))
                        }
                    }
                }
            }
        }
    }
}

struct AuditRowView: View {
    @EnvironmentObject var engine: Engine
    let row: Engine.AuditRow
    var body: some View {
        HStack(spacing: D.Space.m) {
            Thumb(path: row.path, side: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(pretty(row.before)).strikethrough().foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").font(.system(size: 15)).foregroundStyle(.tertiary)
                    Text(pretty(row.after)).foregroundStyle(D.keep)
                    if row.before.prefix(10) != row.after.prefix(10) {
                        Badge(text: "DIFFERENT DAY", color: D.attention)
                    }
                }
                .font(.system(size: 21)).monospacedDigit()
                Text(row.finding.note).font(.system(size: 15)).foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Why?") { engine.inspect(row.finding.clusterID) }.buttonStyle(.link).font(.system(size: 15))
            Button("Correct") { engine.correct([row]) }.controlSize(.regular).disabled(engine.progress.running)
        }
    }
}

/// Days whose timezone the evidence cannot settle, each with its ballot.
struct BallotsSection: View {
    @EnvironmentObject var engine: Engine
    var body: some View {
        VStack(alignment: .leading, spacing: D.Space.l) {

                        HStack(alignment: .firstTextBaseline) {
                            SectionLabel(text: "Which time zone was each day?")
                            Badge(text: engine.ballots.count == 1 ? "1 DAY" : "\(engine.ballots.count) DAYS",
                                  color: D.attention)
                            Spacer()
                        }
                        Text("These days carry a clock but no timezone, so their times cannot be ordered against photographs from anywhere else. The app will not guess one. Below is what each day's own evidence implies — choose, or leave it blank.")
                            .font(.system(size: 15)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(engine.ballots, id: \.day) { b in
                            BallotCard(ballot: b)
                        }
                    
        }
    }
}

/// One day's ballot. The point of this view is the *evidence*, not the ranking:
/// a person can only sensibly choose a timezone if they can see why each one is
/// on the list (PLAN §3, the trust ladder — understand before you tune).
struct BallotCard: View {
    @EnvironmentObject var engine: Engine
    let ballot: Resolver.DayBallot
    @State private var showWorking = false

    private var b: Ballot.Result { ballot.ballot }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: D.Space.m) {
                HStack(alignment: .firstTextBaseline, spacing: D.Space.s) {
                    Text(ballot.dateLabel).font(.system(size: 22, weight: .semibold))
                    Text("\(ballot.photographs) photograph\(ballot.photographs == 1 ? "" : "s")")
                        .font(.system(size: 15)).foregroundStyle(.secondary)
                    Spacer()
                    if b.indistinguishable {
                        Badge(text: "UNSURE", color: D.attention)
                    }
                }

                if b.indistinguishable, b.ranked.count > 1 {
                    Text("The evidence cannot separate \(b.ranked[0].offsetString) from \(b.ranked[1].offsetString). Both are offered; neither is recommended.")
                        .font(.system(size: 15)).foregroundStyle(D.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: D.Space.xs) {
                    ForEach(Array(b.ranked.enumerated()), id: \.offset) { i, cand in
                        CandidateRow(candidate: cand,
                                     leading: i == 0 && !b.indistinguishable,
                                     showWorking: showWorking) {
                            engine.choose(day: ballot.day, offset: cand.offsetString)
                        }
                    }
                }

                // A DisclosureGroup only takes a click on its chevron, which is a
                // 12-point target for the one control that explains the whole card.
                Button { withAnimation(.snappy(duration: 0.18)) { showWorking.toggle() } } label: {
                    HStack(spacing: D.Space.xs) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 16, weight: .semibold))
                            .rotationEffect(.degrees(showWorking ? 90 : 0))
                        Text(showWorking ? "Evidence" : "What is this based on?")
                            .font(.system(size: 15).weight(.medium))
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                if showWorking {
                    VStack(alignment: .leading, spacing: D.Space.xs) {
                        ForEach(b.signals, id: \.self) { line in
                            Text("• " + line)
                                .font(.system(size: 20)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text("Signals are scored separately and averaged with equal weight, never blended into one confident number. Back-tested on days whose zone is known: when this ballot commits to an answer it is right 97% of the time, and the truth is among the three offered 95% of the time.")
                            .font(.system(size: 18)).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                    .transition(.opacity)
                }
            }
        }
    }
}

struct CandidateRow: View {
    let candidate: Ballot.Candidate
    let leading: Bool
    let showWorking: Bool
    let choose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: D.Space.s) {
                Text(candidate.offsetString)
                    .font(.system(size: 22, weight: leading ? .semibold : .regular,
                                  design: .monospaced))
                    .frame(width: 62, alignment: .leading)
                Capsule().fill(.quaternary).frame(height: 5)
                    .overlay(alignment: .leading) {
                        GeometryReader { geo in
                            Capsule()
                                .fill(leading ? D.keep : D.attention)
                                .frame(width: geo.size.width * candidate.score, height: 5)
                        }
                    }
                    .frame(height: 5)
                Text(String(format: "%.0f%%", candidate.score * 100))
                    .font(.system(size: 18, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 34, alignment: .trailing)
                Button("Use this", action: choose)
                    .controlSize(.regular)
                    .buttonStyle(leading ? AnyButtonStyle(.bigProminent)
                                         : AnyButtonStyle(.bigBordered))
            }
            // Per-signal, never a blended number: the reason this offset is here.
            // With one signal the breakdown only repeats the total, so it is hidden.
            if showWorking, candidate.perSignal.count > 1 {
                HStack(spacing: D.Space.m) {
                    ForEach(Array(candidate.perSignal.enumerated()), id: \.offset) { _, s in
                        Text("\(s.0) \(String(format: "%.0f%%", s.1 * 100))")
                            .font(.system(size: 16))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.leading, 70)
            }
        }
    }
}

/// SwiftUI's button styles are distinct types; this lets one call site pick.
struct AnyButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: PrimitiveButtonStyle>(_ style: S) {
        make = { AnyView(Button($0).buttonStyle(style)) }
    }
    init<S: ButtonStyle>(_ style: S) {
        make = { AnyView(Button($0).buttonStyle(style)) }
    }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

struct CoverageCard: View {
    let title: String, have: Int, total: Int, note: String
    private var pct: Int { total > 0 ? have * 100 / total : 0 }

    var body: some View {
        Card {
            HStack(alignment: .center, spacing: D.Space.l) {
                Ring(fraction: total > 0 ? Double(have) / Double(total) : 0)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 20, weight: .semibold))
                    Text("\(have.formatted()) of \(total.formatted())")
                        .font(.system(size: 16).monospacedDigit()).foregroundStyle(.secondary)
                    Text(note).font(.system(size: 15)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - dials

// MARK: - thumbnails

/// Thumbnails. Three choices, each made after the simpler one failed:
///
/// * **ImageIO, not QuickLook.** Requesting only `.thumbnail` fails whenever
///   QuickLook cannot produce a high-quality one quickly, and that failure looks
///   exactly like "still loading" — most rows stayed permanently blank.
/// * **`NSCache`, not an `actor`.** An actor serialises its methods, so one slow
///   video decode stalled every thumbnail behind it. `NSCache` is already
///   thread-safe and evicts under memory pressure, so no serialisation is needed.
/// * **A global queue, not `Task.detached`.** Awaiting a detached task inside
///   `.task(id:)` meant that when SwiftUI rebuilt the list and cancelled the view's
///   task, execution stopped at the await — so neither the image nor the failure
///   state was ever set, and the row stayed blank forever.
enum Thumbnails {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 600
        return c
    }()
    private static let queue = DispatchQueue(label: "thumbnails",
                                             qos: .userInitiated, attributes: .concurrent)

    static func image(_ path: String, side: CGFloat) async -> NSImage? {
        let key = "\(path)|\(Int(side))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let img: NSImage? = await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: render(path, side * 2)) }
        }
        if let img { cache.setObject(img, forKey: key) }
        return img
    }

    static func render(_ path: String, _ maxPixel: CGFloat) -> NSImage? {
        let url = URL(fileURLWithPath: path)
        if ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()) {
            // ImageIO cannot open a movie container. Take a frame 10% in, which
            // avoids the black or partial first frame many containers carry.
            let asset = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
            gen.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
            gen.requestedTimeToleranceAfter  = CMTime(seconds: 1, preferredTimescale: 600)
            let dur = CMTimeGetSeconds(asset.duration)
            let t = CMTime(seconds: dur.isFinite && dur > 0 ? dur * 0.1 : 0,
                           preferredTimescale: 600)
            guard let cg = try? gen.copyCGImage(at: t, actualTime: nil) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel),
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

struct Thumb: View {
    let path: String?
    let side: CGFloat
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quinary)
                Image(systemName: failed ? (isVideo ? "play.rectangle" : "photo") : "")
                    .font(.system(size: side * 0.26, weight: .light))
                    .foregroundStyle(.quaternary)
            }
        }
        .frame(width: side, height: side)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: side > 60 ? D.Radius.card : D.Radius.small))
        .overlay(
            RoundedRectangle(cornerRadius: side > 60 ? D.Radius.card : D.Radius.small)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        )
        .task(id: path) {
            debugLog("thumb start \(Int(side)) \(path ?? "nil")")
            guard let path, image == nil else { return }
            if let img = await Thumbnails.image(path, side: side) {
                debugLog("thumb done \(Int(side)) cancelled=\(Task.isCancelled)")
                image = img
            } else {
                failed = true
            }
        }
    }

    private var isVideo: Bool {
        guard let p = path?.lowercased() else { return false }
        return p.hasSuffix(".mov") || p.hasSuffix(".mp4") || p.hasSuffix(".m4v")
    }
}
