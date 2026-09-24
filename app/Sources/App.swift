import SwiftUI
import AppKit

/// Window restoration is off: macOS otherwise reopens whatever was open at quit,
/// and a session that ended with only Help open — or none — relaunched to a bare
/// menu bar. PhotoMerge always opens on its main window instead.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ n: Notification) {
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        // dev aid: `open --env PM_DARK=1 …` shows the dark appearance for one launch
        if ProcessInfo.processInfo.environment["PM_DARK"] != nil { NSApp.appearance = NSAppearance(named: .darkAqua) }
    }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
    func applicationShouldSaveApplicationState(_ app: NSApplication) -> Bool { false }
    func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool { false }
    /// Clicking the Dock icon with no window open brings the main window back.
    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows flag: Bool) -> Bool { !flag }
}

@main
struct PhotoMergeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var engine = Engine()

    init() {
        // SwiftUI restores its own scene state regardless of the delegate's answer;
        // a saved state with no window open relaunched to a bare menu bar. Ignoring
        // saved state is the one switch both AppKit and SwiftUI honour.
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
    }
    @State private var welcome = false

    var body: some Scene {
        WindowGroup("PhotoMerge") {
            ContentView()
                .environmentObject(engine)
                .frame(minWidth: 1000, minHeight: 680)
                .onAppear { engine.open() }
                .sheet(isPresented: $welcome) { WelcomeSheet() }
                .onAppear {
                    // A development launch (PM_* set) must not use up the person's welcome;
                    // PM_WELCOME=1 shows it without marking it seen.
                    let env = ProcessInfo.processInfo.environment
                    if env["PM_WELCOME"] == "1" { welcome = true; return }
                    guard !env.keys.contains(where: { $0.hasPrefix("PM_") }) else { return }
                    if !UserDefaults.standard.bool(forKey: "welcomed") {
                        UserDefaults.standard.set(true, forKey: "welcomed"); welcome = true
                    }
                }
        }

        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            AppCommands(engine: engine)
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Analysis") {
                Button("Analyse") { engine.analyse() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(engine.sources.isEmpty || engine.progress.running)
                Button("Stop") { engine.cancel() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!engine.progress.running)
            }
            CommandGroup(after: .saveItem) {
                Button("Export Findings…") { engine.exportFindings() }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(engine.stats.assets == 0)
            }
            CommandGroup(after: .toolbar) {
                Toggle("Advanced Tools", isOn: $engine.advanced)
                    .keyboardShortcut("a", modifiers: [.command, .option])
                Divider()
                ForEach(Array(Tab.allCases.enumerated()), id: \.element) { i, t in
                    Button(t.rawValue) { engine.advanced = true; engine.tab = t }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
            }
            // One undo history for every choice. While a text field is being edited
            // it keeps its own ⌘Z, as everywhere on the Mac.
            CommandGroup(replacing: .undoRedo) {
                let _ = engine.undoTick
                Button(engine.undoManager.canUndo ? "Undo \(engine.undoManager.undoActionName)" : "Undo") {
                    if let t = NSApp.keyWindow?.firstResponder as? NSTextView { t.undoManager?.undo() }
                    else { engine.undoManager.undo() }
                }
                .keyboardShortcut("z", modifiers: .command)
                Button(engine.undoManager.canRedo ? "Redo \(engine.undoManager.redoActionName)" : "Redo") {
                    if let t = NSApp.keyWindow?.firstResponder as? NSTextView { t.undoManager?.redo() }
                    else { engine.undoManager.redo() }
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
        }
    }
}

/// About, and Help — offline, in its own window.
struct AppCommands: Commands {
    @ObservedObject var engine: Engine
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About PhotoMerge") {
                let credits = NSAttributedString(string:
                    "Tidies photo collections on your Mac — offline.\n\nPlace names: GeoNames, CC BY 4.0.\nMetadata: ExifTool by Phil Harvey.",
                    attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
                NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        CommandGroup(replacing: .help) {
            Button("PhotoMerge Help") { HelpController.shared.show() }
                .keyboardShortcut("?", modifiers: .command)
        }
    }
}

enum Tab: String, CaseIterable, Identifiable {
    case sources = "Sources", groups = "Duplicates", timeline = "Dates & places",
         decisions = "Decisions", fill = "Fill in", dials = "Settings", write = "Clean library"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .sources:  return "folder"
        case .groups:   return "square.on.square"
        case .timeline: return "calendar.badge.clock"
        case .decisions: return "questionmark.bubble"
        case .write:     return "square.and.arrow.down.on.square"
        case .fill:      return "square.and.pencil"
        case .dials:    return "slider.horizontal.3"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var engine: Engine
    var body: some View {
        Group {
            // dev aid: PM_HELP=inline shows Help in the main window, for a screenshot
            if let t = engine.catalogTrouble { CatalogTroubleView(url: t.url, why: t.why) }
            else if ProcessInfo.processInfo.environment["PM_HELP"] == "inline" { HelpWindow() }
            else if engine.advanced { AdvancedView() } else { GuidedView() }
        }
        .font(.system(size: 20))   // the default for anything unstyled; macOS ignores dynamicTypeSize, so every style is an explicit size, 1.5× the system's
        .buttonStyle(.bigBordered) // buttons to match; see BigButton
        .onAppear { if ProcessInfo.processInfo.environment["PM_HELP"] == "1" { HelpController.shared.show() } }
    }
}

/// The catalog — the app's own record of what it read and what you decided — would
/// not open. The photographs are untouched; the record can be put aside and rebuilt.
struct CatalogTroubleView: View {
    @EnvironmentObject var engine: Engine
    let url: URL, why: String
    var body: some View {
        EmptyState(icon: "externaldrive.badge.exclamationmark", title: "PhotoMerge's records could not be opened",
                   message: "The file that holds what the app read and what you decided (\(url.lastPathComponent)) would not open: \(why). Your photos are not affected. You can put the file aside and start again — the folders you added are read afresh, and choices made so far are lost.") {
            HStack {
                Button("Show the file") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Put it aside and start again") { engine.startFreshCatalog() }.buttonStyle(.bigProminent)
            }
        }
        .padding(D.Space.xl).background(D.canvas)
    }
}

/// Every pane, for those who want them all (View → Advanced Tools).
struct AdvancedView: View {
    @EnvironmentObject var engine: Engine
    var body: some View {
        NavigationSplitView {
            List(selection: $engine.tab) {
                Section {
                    ForEach(Tab.allCases) { t in
                        NavigationLink(value: t) {
                            Label {
                                HStack {
                                    Text(t.rawValue)
                                    Spacer()
                                    if let c = count(for: t) {
                                        Text("\(c)")
                                            .font(.system(size: 15)).monospacedDigit()
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            } icon: {
                                Image(systemName: t.icon)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 230, ideal: 250, max: 300)
            .safeAreaInset(edge: .top) { BackToSteps() }
            .safeAreaInset(edge: .bottom) { SidebarFooter() }
        } detail: {
            VStack(spacing: 0) {
                Scoreboard()
                Divider()
                Group {
                    switch engine.tab {
                    case .sources:  SourcesView()
                    case .groups:   GroupsView()
                    case .timeline: TimelineView()
                    case .decisions: DecisionsView()
                    case .write:     WriteView()
                    case .fill:      FillView()
                    case .dials:    DialsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(D.canvas)
                Divider()
                StatusBar()
            }
        }
    }

    private func count(for t: Tab) -> Int? {
        switch t {
        case .sources:  return engine.sources.isEmpty ? nil : engine.sources.count
        case .groups:   return engine.groups.isEmpty ? nil : engine.groups.count
        default:        return nil
        }
    }
}

/// The way back to the four steps, at the top of the sidebar where it cannot be
/// missed — the sidebar is the side road, the steps are the main one.
struct BackToSteps: View {
    @EnvironmentObject var engine: Engine
    var body: some View {
        VStack(spacing: D.Space.s) {
            Button { engine.advanced = false } label: {
                Label("Back to steps", systemImage: "arrow.uturn.backward")
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bigProminent)
            .help("Return to Add photos → Duplicates → Time & place → Save (⌥⌘A). These panes show every detail; nothing here is lost.")
            // No caption: wrapping text in a sidebar inset is measured at zero width
            // and its height pushed the whole window's content off the top.
        }
        .padding(.horizontal, D.Space.m).padding(.top, D.Space.s).padding(.bottom, D.Space.m)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct SidebarFooter: View {
    @EnvironmentObject var engine: Engine
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Divider().padding(.bottom, D.Space.xs)
            Label("Originals protected", systemImage: "lock.shield")
                .font(.system(size: 15)).foregroundStyle(.secondary)
            Text("Only ever writes new copies")
                .font(.system(size: 15)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, D.Space.m)
        .padding(.bottom, D.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - scoreboard

struct Scoreboard: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        let s = engine.stats
        HStack(alignment: .top, spacing: 0) {
            group {
                Metric(value: s.files.formatted(), label: "files")
                Metric(value: s.assets.formatted(), label: s.assets == 1 ? "photograph" : "photographs")
            }
            sep
            group {
                Metric(value: s.duplicates.formatted(), label: "duplicates",
                       tint: s.duplicates > 0 ? D.attention : nil,
                       help: "Extra copies of a photograph you already have")
                Metric(value: byteString(s.wastedBytes), label: "recoverable",
                       tint: s.wastedBytes > 0 ? D.attention : nil)
            }
            sep
            group {
                Metric(value: "\(s.pctDated)%", label: "dated",
                       fraction: Double(s.pctDated) / 100)
                Metric(value: "\(s.pctZoned)%", label: "zone",
                       fraction: Double(s.pctZoned) / 100)
                Metric(value: "\(s.pctLocated)%", label: "place",
                       fraction: Double(s.pctLocated) / 100)
            }
            if s.inferredPlace + s.guessedTime > 0 {
                sep
                group {
                    Metric(value: "\(s.inferredPlace + s.guessedTime)", label: "estimated",
                           tint: D.attention,
                           help: "\(s.inferredPlace) places and \(s.guessedTime) dates the app worked out rather than read")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, D.Space.m)
        .background(.bar)
    }

    private var sep: some View {
        Rectangle().fill(.quaternary)
            .frame(width: 1, height: 34)
            .padding(.horizontal, 18)
    }

    private func group<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        HStack(alignment: .top, spacing: 22) { c() }
    }
}

// MARK: - status bar

struct StatusBar: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        let p = engine.progress
        HStack(spacing: D.Space.m) {
            if p.running {
                ProgressView().controlSize(.regular).scaleEffect(0.8)
                Text(stageLabel(p.stage))
                    .font(.system(size: 18).weight(.medium))
                if p.total > 0 {
                    ProgressView(value: p.fraction)
                        .frame(width: 160)
                    Text("\(p.done) of \(p.total)")
                        .font(.system(size: 15)).monospacedDigit().foregroundStyle(.secondary)
                } else if p.done > 0 {
                    Text("\(p.done) files")
                        .font(.system(size: 15)).monospacedDigit().foregroundStyle(.secondary)
                }
                Spacer()
                Button("Stop", role: .destructive) { engine.cancel() }
                    .controlSize(.regular)
            } else {
                Image(systemName: engine.notice != nil ? "square.and.arrow.up"
                                  : p.stage == "done" ? "checkmark.circle.fill" : "info.circle")
                    .foregroundStyle(p.stage == "done" || engine.notice != nil
                                     ? AnyShapeStyle(D.keep) : AnyShapeStyle(.tertiary))
                    .font(.system(size: 15))
                Text(engine.notice ?? (p.stage == "done"
                     ? "Finished. Nothing was written — every file is exactly as you left it."
                     : p.stage == "cancelled"
                     ? "Stopped. Everything read so far is kept — Analyse (⌘R) reads only the rest."
                     : p.stage == "written"
                     ? "Finished writing. Every file was read back and verified; your originals were not touched."
                     : "Your originals are never modified. The merged copy is a separate folder you choose."))
                    .font(.system(size: 15)).foregroundStyle(.secondary)
                Spacer()
                Text("\(engine.workerCount) cores")
                    .font(.system(size: 18)).foregroundStyle(.quaternary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func stageLabel(_ s: String) -> String {
        switch s {
        case "scanning":  return "Looking for files"
        case "reading":   return "Reading photographs"
        case "grouping":  return "Finding duplicates"
        case "resolving": return "Working out dates and places"
        case "stopping":  return "Stopping after the current batch…"
        case "writing":   return "Writing and verifying the merged copy"
        default:          return s.capitalized
        }
    }
}
