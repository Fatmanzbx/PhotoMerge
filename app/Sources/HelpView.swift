import SwiftUI
import AppKit

// MARK: - help, offline

struct HelpTopic: Identifiable, Hashable {
    let id: String, title: String, icon: String, body: String
}

enum HelpContent {
    static let topics: [HelpTopic] = [
        .init(id: "start", title: "Getting started", icon: "sparkles", body: """
        PhotoMerge tidies a photo collection in four steps, across the top of the window.

        **1 · Add photos.** Drag folders into the window, or choose them. A Google Takeout, an old backup drive, a folder of phone photos, your Photos library — as many as you like. PhotoMerge starts reading at once and shows results as it goes. You can quit at any time; it carries on where it stopped.

        **2 · Duplicates.** Every photo it has more than one copy of, with the copy it keeps and why. The kept copy takes its date, time zone and place from all its copies together. *How alike is a duplicate?* sets how loosely photos are matched, tried on your photos before you apply it. Look-alikes it will not decide on its own — one shot, edited — wait under *Edited copies* for your say.

        **3 · Time & place.** *Worked out for you* shows how many photos have a date, a time zone and a place, the few things put to you (a time that contradicts its place, a day whose zone is unclear), and how far a photo without GPS may borrow a place. Places the app worked out — from photos of the same day, a photo near in time, or the same folder — are gathered by area (50 km) so you can look them over: if a few are wrong, give them their real place under *Fill in by hand* first (they leave the area), then *Accept all* for the rest. *Fill in by hand* is a grid of the photos still missing a date or a place, and of those with a worked-out place: select many at once and give them a day, a place, or both. Take steps 2 and 3 in either order, as often as you like. Save opens once every photo has a date and a place — or once you choose to *leave the rest as they are*.

        **4 · Save.** Either a clean new library, or a tidy-up in place. Nothing is changed before this step.
        """),
        .init(id: "dupes", title: "Duplicates and edited copies", icon: "square.on.square", body: """
        **Duplicates** are copies of one photo — the same file saved twice, or re-saved at a different size or quality. PhotoMerge keeps the best copy of each (the most pixels, then the largest file) and treats the rest as extras. To keep a different one, open the group and choose *Keep this copy instead*, or press its number key.

        Two photos taken a second apart are never duplicates, however alike: every copy of one photo shares the moment it was taken, and burst frames do not.

        **Edited copies** are one shot that was cropped, filtered or brightened. Whether an edit is "the same photo" is your call, so PhotoMerge asks. *Compare* shows them side by side or flipped in one frame, which is how a difference becomes visible.
        """),
        .init(id: "time", title: "Dates and time zones", icon: "clock", body: """
        Most photos record when they were taken. Some record only the clock time without saying where in the world that clock was — the time zone — and some record nothing.

        PhotoMerge reads everything a file offers, and fills gaps from evidence: a Google Takeout sidecar, the filename, other photos taken nearby that day. Anything worked out rather than read is marked **Estimated**, in orange.

        **Photos showing the wrong time** record a time zone that cannot be right: not the one clocks showed where they were taken, or not the one on photos taken at the same place and minute. A camera left on home time for a whole trip shows up here. Correcting keeps the moment each was taken and fixes the clock.

        **Unclear days** have photos whose time zone the evidence cannot settle. PhotoMerge suggests the likeliest; you choose.
        """),
        .init(id: "place", title: "Places", icon: "mappin.and.ellipse", body: """
        A photo with GPS knows where it was taken. For one without, PhotoMerge looks for a photo taken nearby in time on the same day, or a folder whose photos were all taken in one spot. Places found this way are marked **Estimated**.

        Places are shown by the nearest town, from a list of 34,000 cities built into the app — no internet is used. Far from any town, the coordinates are shown instead.

        To place many photos at once, see *Filling in by hand*.
        """),
        .init(id: "fill", title: "Filling in by hand", icon: "square.and.pencil", body: """
        *Fill in* shows every photo without a date or a place.

        **Select** as in Finder: click one; ⌘-click to add or remove; ⇧-click to select a range; or drag a box across the photos.

        **Give them a day and a place.** Type a city — "Lisbon", "東京" — or coordinates copied from a map app, and apply to everything selected. A day has no time of day, so a saved copy records it as noon.

        What you enter only fills gaps: a date or GPS a file records is never replaced.
        """),
        .init(id: "save", title: "Saving the result", icon: "square.and.arrow.down", body: """
        **Save a clean library** writes a new folder with one file per photo, named by when it was taken (2019/07/20190714_120000.jpg), duplicates left out, and dates, time zones and places written into each file. Every file is read back and checked against its original before it counts. Your originals are not changed.

        **Tidy in place** moves the extra copies to the Trash, where you can put them back. A copy is moved only if the one being kept is still there and unchanged, so the last copy of a photo is never moved. Photos inside a Photos library are never moved — that would damage the library.
        """),
        .init(id: "undo", title: "Undo and safety", icon: "arrow.uturn.backward", body: """
        **⌘Z undoes** any choice — a correction, a time zone, what you filled in, the copy to keep, moving copies to the Trash — and ⇧⌘Z redoes it.

        PhotoMerge never changes a file you added. Its decisions are kept in its own catalog, and only *Save* writes anything: a new folder, or extras moved to the Trash.
        """),
        .init(id: "privacy", title: "Privacy", icon: "lock.shield", body: """
        PhotoMerge works entirely on your Mac. It does not connect to the internet, send photos anywhere, or use an online service to recognise places or faces. Place names come from a list inside the app.
        """),
        .init(id: "advanced", title: "Advanced tools", icon: "slider.horizontal.3", body: """
        View → Advanced Tools (⌥⌘A), or *All panes* at the top right, shows every pane with a sidebar: the reasoning behind any photo's date and place (*Decisions*), matching and place settings with a preview of their effect (*Settings*), the timeline, exclusions, place rules and exports. *Back to the guided view*, at the foot of the sidebar, returns to the four steps. Both are the same app; nothing is lost between them.
        """),
        .init(id: "credits", title: "Acknowledgements", icon: "heart", body: """
        **Place names** from GeoNames (https://www.geonames.org), licensed under Creative Commons Attribution 4.0.

        **Writing metadata** uses ExifTool by Phil Harvey (https://exiftool.org), free software under the same terms as Perl (GPL or Artistic License), included unmodified as a separate program.
        """),
    ]
}

struct HelpWindow: View {
    @State private var selection: String = "start"
    var body: some View {
        // a plain two-column layout: a NavigationSplitView hosted in an AppKit
        // window rendered nothing at all
        HStack(spacing: 0) {
            List(HelpContent.topics, selection: Binding(get: { selection }, set: { if let v = $0 { selection = v } })) { t in
                Label(t.title, systemImage: t.icon).tag(t.id)
            }
            .listStyle(.sidebar)
            .frame(width: 210)
            Divider()
            if let t = HelpContent.topics.first(where: { $0.id == selection }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: D.Space.m) {
                        Label(t.title, systemImage: t.icon).font(.system(size: 33, weight: .semibold))
                        ForEach(Array(t.body.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, para in
                            Text((try? AttributedString(markdown: para)) ?? AttributedString(para))
                                .font(.system(size: 22)).lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: 620, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}

/// The Help window, created on first use. An AppKit window rather than a second
/// SwiftUI scene: with two scenes declared, the app stopped opening its main
/// window at launch.
final class HelpController {
    static let shared = HelpController()
    private var window: NSWindow?
    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "PhotoMerge Help"
            w.isReleasedWhenClosed = false
            // Without this the hosting controller sizes the window to the split
            // view's ideal size — which is 2×2 points.
            let host = NSHostingController(rootView: HelpWindow().font(.system(size: 20)).buttonStyle(.bigBordered))
            host.sizingOptions = []
            w.contentViewController = host
            w.setContentSize(NSSize(width: 820, height: 560))
            w.contentMinSize = NSSize(width: 720, height: 480)
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - welcome, once

struct WelcomeSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: D.Space.l) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            Text("Welcome to PhotoMerge").font(.system(size: 36, weight: .semibold))
            VStack(alignment: .leading, spacing: D.Space.m) {
                row("photo.on.rectangle.angled", "Add your photos", "Folders, drives, a Google Takeout, your Photos library.")
                row("square.on.square", "Sort out duplicates", "The best copy of each is kept, with what every copy knew.")
                row("calendar.badge.clock", "Give every photo a time and place", "Worked out for you where it can be; fill in the rest by hand, many at once.")
                row("lock.shield", "Nothing changes until you save", "Every choice can be undone with ⌘Z. Nothing leaves your Mac.")
            }
            Button("Get started") { dismiss() }
                .buttonStyle(.bigProminent).controlSize(.extraLarge).keyboardShortcut(.defaultAction)
        }
        .padding(32).frame(width: 460)
    }
    private func row(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: D.Space.m) {
            Image(systemName: icon).font(.system(size: 33)).foregroundStyle(Color.accentColor).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 22, weight: .semibold))
                Text(text).font(.system(size: 18)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - a tip, shown once

/// A single sentence at the moment it is useful, dismissed for good once read
/// (Apple HIG: short, actionable tips instead of a tutorial).
struct TipBanner: View {
    let id: String
    let icon: String
    let text: String
    @AppStorage private var dismissed: Bool
    init(id: String, icon: String, text: String) {
        self.id = id; self.icon = icon; self.text = text
        _dismissed = AppStorage(wrappedValue: false, "tip." + id)
    }
    var body: some View {
        if !dismissed {
            HStack(spacing: D.Space.s) {
                Image(systemName: icon).foregroundStyle(Color.accentColor)
                Text(text).font(.system(size: 18)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: D.Space.s)
                Button { dismissed = true } label: { Image(systemName: "xmark").font(.system(size: 15)) }
                    .accessibilityLabel("Dismiss this tip")
                    .buttonStyle(.borderless).help("Don't show this tip again")
            }
            .padding(.horizontal, D.Space.m).padding(.vertical, D.Space.s)
            .background(RoundedRectangle(cornerRadius: D.Radius.small).fill(Color.accentColor.opacity(0.10)))
        }
    }
}
