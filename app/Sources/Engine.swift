import Foundation
import Combine
import AppKit
import UniformTypeIdentifiers

/// Orchestrates scan → extract → cluster, reporting progress as it goes.
/// v1 writes nothing outside the catalog (PLAN §3, the trust ladder).
@MainActor
final class Engine: ObservableObject {

    struct Progress {
        var stage: String = "idle"
        var done: Int = 0
        var total: Int = 0
        var detail: String = ""
        var running: Bool = false
        var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
    }

    struct Stats {
        var files = 0, images = 0, videos = 0
        var assets = 0, duplicates = 0
        var wastedBytes = 0
        var dated = 0, zoned = 0, located = 0
        var inferredPlace = 0, guessedTime = 0
        var pctDated: Int { assets > 0 ? dated * 100 / assets : 0 }
        var pctZoned: Int { assets > 0 ? zoned * 100 / assets : 0 }
        var pctLocated: Int { assets > 0 ? located * 100 / assets : 0 }
    }

    @Published var progress = Progress()
    @Published var stats = Stats()
    @Published var sources: [String] = []
    @Published var groups: [Group] = []
    @Published var radius: Int = 4
    /// Which pane is showing. On the model so the menu bar can move it (⌘1…⌘5).
    @Published var tab: Tab = .sources

    // Decisions pane
    @Published var decisionFilter: Decisions.Filter = .inferred
    @Published var decisionRows: [Decisions.Row] = []
    @Published var decisionTotal = 0
    @Published var decisionSelection: Int?
    /// The resolver dials currently in force — what produced the stored result.
    @Published var params = Resolver.Params()
    /// Days the resolver could not zone, with the offsets it would offer (PLAN §7.4).
    @Published var ballots: [Resolver.DayBallot] = []
    /// Days you settled yourself. Kept visible so every choice can be taken back.
    @Published var settled: [Settled] = []

    struct Settled: Identifiable {
        let day: Int
        let offset: String
        let label: String
        let photographs: Int
        var id: Int { day }
    }

    private var catalog: Catalog?
    private var task: Task<Void, Never>?

    /// Sized to performance cores — measured: 10 beats 14 (SPIKES §3).
    private static let workers = Ingest.workers

    var workerCount: Int { Engine.workers }

    // MARK: lifecycle

    /// Why the catalog could not be opened, and where it is, for the recovery screen.
    @Published var catalogTrouble: (url: URL, why: String)?

    /// Put the catalog that will not open aside and start a fresh one. Nothing but
    /// the app's own records is affected; the photographs are read again.
    func startFreshCatalog() {
        guard let t = catalogTrouble else { return }
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        for suffix in ["", "-wal", "-shm"] {
            let p = t.url.path + suffix
            if fm.fileExists(atPath: p) { try? fm.moveItem(atPath: p, toPath: t.url.path + ".broken-\(stamp)" + suffix) }
        }
        catalogTrouble = nil
        open()
    }

    func open() {
        guard catalog == nil else { return }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoMerge", isDirectory: true)
        // dev aid: `open -g --env PM_CATALOG=/path/c.sqlite …` opens another catalog,
        // so the flow can be looked at on a test collection without touching the real one.
        let url = ProcessInfo.processInfo.environment["PM_CATALOG"].map { URL(fileURLWithPath: $0) }
            ?? dir.appendingPathComponent("catalog.sqlite")
        do { catalog = try Catalog(url: url) }
        catch {
            // Every method guards `catalog`; this is the one place it is made. A locked,
            // corrupt or unwritable catalog must not crash every launch (review finding 7).
            catalogTrouble = (url, "\(error)")
            return
        }
        if let c = catalog { params = Pipeline.params(c); radius = Pipeline.radius(c) }
        // dev aid: `open -g --env PM_TAB=write …` opens on a pane without any input
        if let t = ProcessInfo.processInfo.environment["PM_TAB"],
           let tab = Tab.allCases.first(where: { "\($0)" == t }) { self.tab = tab }
        refreshSources()
        refreshStats()
        refreshBreakdown()
        loadGroups()          // a previous run's findings are already in the catalog
        loadReview()
        loadAct()
        loadAudit()
        loadRules()
        loadAcks()
        loadFill()
        loadTidy()
        if stats.assets > 0, step == .add { step = .duplicates }
        // dev aid: `open --env PM_ANALYSE=1 …` starts reading at launch, as pressing
        // Read them would — so a run can be started without any synthetic input.
        if ProcessInfo.processInfo.environment["PM_ANALYSE"] != nil { step = .add; analyse() }
        // dev aid, like PM_TAB: `open -g --env PM_STEP=save …`
        if let st = ProcessInfo.processInfo.environment["PM_STEP"],
           let s = Guide.Step.allCases.first(where: { "\($0)" == st }) { step = s }
        if staleChoices(catalog!) {
            // The stored resolution credits a choice that no longer exists — the
            // catalog was edited from outside, or copied from another machine.
            // Stage 4 is cheap and derived, so rebuild it rather than display a lie.
            reresolve()
        } else {
            loadBallots()     // a previous run's open questions are still open
        }
    }

    func addSource(_ url: URL) {
        guard let c = catalog else { return }
        // A Photos library is a package; its photographs are in originals/.
        var url = url
        if url.pathExtension == "photoslibrary" { url = url.appendingPathComponent("originals") }
        try? c.transaction {
            let st = try c.prepare("INSERT OR IGNORE INTO source(path, added_at) VALUES(?,?);")
            st.bind(1, url.path).bind(2, Date().timeIntervalSince1970).done()
            st.finalize()
        }
        refreshSources()
    }

    func removeAll() {
        guard let c = catalog else { return }
        try? c.transaction {
            // everything derived from the files goes with them; a manifest or trash row
            // left behind would attach to an unrelated new file with a reused id
            try c.run("DELETE FROM output; DELETE FROM trashed; DELETE FROM resolution; DELETE FROM pair; "
                    + "DELETE FROM member; DELETE FROM cluster; DELETE FROM file; DELETE FROM source;")
        }
        groups = []
        refreshSources(); refreshStats()
    }

    /// Stop at the next batch boundary. The task is kept until it has actually
    /// finished — worker threads are still writing their last batch — so a new run
    /// cannot start on top of a stopping one.
    func cancel() {
        stop.set()
        task?.cancel()
        progress.stage = "stopping"
    }
    private var stop = Ingest.Stop()

    // MARK: the run

    func analyse() {
        guard let c = catalog, task == nil else { return }
        progress = Progress(stage: "scanning", running: true)
        notice = nil
        stop = Ingest.Stop()
        let stop = self.stop
        task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.scan(c, stop)
            if !stop.isSet { await self.extractAll(c, stop) }
            // Group and resolve whatever was read, even after a stop: what is in
            // the catalog is real, and the next run only reads the remainder.
            await self.cluster(c)
            await self.resolveAll(c)
            await MainActor.run {
                self.progress.running = false
                self.progress.stage = stop.isSet ? "cancelled" : "done"
                self.task = nil
                // Show the findings, but only if they are still on the pane they
                // started from — never fight their own navigation. Reopening the app
                // must not move them either, which is why this lives here and not
                // in a view watching the group count.
                if !stop.isSet, self.tab == .sources { self.tab = .groups }
                if !stop.isSet, self.step == .add { self.step = .duplicates }
                self.refreshSources()
                self.refreshStats()
                self.refreshBreakdown()
                self.loadGroups()
                self.loadBallots()
                self.loadDecisions()
                self.loadReview()
                self.loadAudit()
                self.loadFill()
                self.loadTidy()
            }
        }
    }

    // MARK: stages — thin wrappers over `Ingest` and `Pipeline`

    private nonisolated func scan(_ c: Catalog, _ stop: Ingest.Stop) async {
        let r = Ingest.scan(c, stop: stop) { n in
            Task { @MainActor in self.progress.done = n; self.progress.detail = "\(n) files" }
        }
        await MainActor.run {
            self.progress.done = r.seen; self.progress.total = r.seen
            if !r.unavailable.isEmpty {
                self.notice = "Skipped \(r.unavailable.count) source\(r.unavailable.count == 1 ? "" : "s") that could not be found — an unplugged drive? Nothing from \(r.unavailable.count == 1 ? "it" : "them") was forgotten."
            }
            if !r.denied.isEmpty {
                self.notice = "macOS did not let PhotoMerge read \((r.denied[0] as NSString).lastPathComponent). Allow it under System Settings → Privacy & Security → Files and Folders, then read again."
            }
        }
    }

    /// Read everything not yet read. Results are committed batch by batch, and
    /// groups are rebuilt every few seconds while it runs, so the first duplicates
    /// appear long before the last file is read (PLAN §4).
    private nonisolated func extractAll(_ c: Catalog, _ stop: Ingest.Stop) async {
        await MainActor.run { self.progress.stage = "reading"; self.progress.done = 0; self.progress.total = 0 }
        let reading = Ingest.Stop()          // set when extraction ends, to end the refresher
        let refresher = Task.detached(priority: .utility) { [weak self] in
            var last = 0
            var interval: UInt64 = 6_000_000_000
            while !reading.isSet {
                try? await Task.sleep(nanoseconds: interval)
                if reading.isSet { break }
                let now = c.scalarInt("SELECT COUNT(*) FROM file WHERE state='extracted';")
                guard now > last, let self else { continue }
                last = now
                let t0 = Date()
                let radius = await MainActor.run { self.radius }
                _ = try? Pipeline.cluster(c, radius: radius)
                _ = try? Pipeline.resolve(c)
                // never spend more than a fifth of the time regrouping
                let took = Date().timeIntervalSince(t0)
                interval = UInt64(max(6, took * 5) * 1_000_000_000)
                await MainActor.run {
                    self.refreshStats(); self.refreshSources(); self.loadGroups(); self.loadReview()
                }
            }
        }
        _ = Ingest.extract(c, workers: Engine.workers, stop: stop) { done, total in
            Task { @MainActor in self.progress.done = done; self.progress.total = total }
        }
        reading.set()
        _ = await refresher.value
    }

    /// Files found but not yet read — an interrupted run, waiting to be resumed.
    var unread: Int { catalog?.scalarInt("SELECT COUNT(*) FROM file WHERE state='scanned';") ?? 0 }
    var unreadable: Int { catalog?.scalarInt("SELECT COUNT(*) FROM file WHERE state='failed';") ?? 0 }

    /// Identity cascade, most certain first (PLAN §7.1) — the same code the tests
    /// run, via `Pipeline`. Never re-implement a stage here.
    private nonisolated func cluster(_ c: Catalog) async {
        await MainActor.run { self.progress.stage = "grouping"; self.progress.done = 0; self.progress.total = 0 }
        let radius = await MainActor.run { self.radius }
        Pipeline.setRadius(c, radius)
        do { _ = try Pipeline.cluster(c, radius: radius) }
        catch { await MainActor.run { self.notice = "Grouping failed: \(error). The catalog may be full or locked; nothing was lost." } }
    }

    /// Stage 4 — time, place and zone (PLAN §7.2, §7.3), honouring your choices.
    private nonisolated func resolveAll(_ c: Catalog) async {
        await MainActor.run { self.progress.stage = "resolving"; self.progress.done = 0; self.progress.total = 0 }
        let res: Pipeline.Resolution
        do { res = try Pipeline.resolve(c) }
        catch { await MainActor.run { self.notice = "Working out dates and places failed: \(error). Nothing was lost." }; return }
        // Whatever is still unzoned becomes a ballot for the person to settle.
        let bs = Resolver.ballots(res.inputs, res.resolved)
        await MainActor.run { self.ballots = bs }
    }

    // MARK: what you chose

    /// Rebuild the ballots from what is already stored, without re-resolving. A
    /// previous run's open questions are still open when the app is reopened.
    func loadBallots() {
        guard let c = catalog else { return }
        Task.detached(priority: .utility) { [weak self] in
            var resolved: [Resolver.Resolved] = []
            if let st = try? c.prepare("""
                SELECT cluster_id, local_time, time_source, utc_offset, zone_source,
                       lat, lon, place_source, instant FROM resolution;
                """) {
                while st.step() {
                    resolved.append(Resolver.Resolved(
                        clusterID: st.int(0), localTime: st.text(1),
                        timeSource: st.text(2) ?? "none", utcOffset: st.text(3),
                        zoneSource: st.text(4) ?? "none",
                        lat: st.isNull(5) ? nil : st.double(5),
                        lon: st.isNull(6) ? nil : st.double(6),
                        placeSource: st.text(7) ?? "none",
                        instant: st.isNull(8) ? nil : st.double(8)))
                }
                st.finalize()
            }
            guard !resolved.isEmpty else { return }
            let bs = Resolver.ballots(Pipeline.claims(c), resolved)
            let picked = Pipeline.picks(c)
            var counts: [Int: Int] = [:]
            for r in resolved {
                guard let d = Resolver.dayNumber(r.localTime), picked[d] != nil else { continue }
                counts[d, default: 0] += 1
            }
            let se = picked.map { day, off in
                Settled(day: day, offset: off, label: Resolver.dayLabel(day),
                        photographs: counts[day] ?? 0)
            }.sorted { $0.day < $1.day }
            await MainActor.run { self?.ballots = bs; self?.settled = se }
        }
    }

    /// True when the stored resolution and the stored choices disagree: a day
    /// credited to a choice that is gone. The catalog was edited from outside, or
    /// copied from another machine.
    private func staleChoices(_ c: Catalog) -> Bool {
        var credited = Set<Int>()
        if let st = try? c.prepare(
            "SELECT DISTINCT local_time FROM resolution WHERE zone_source = 'you chose it';") {
            while st.step() { if let d = Resolver.dayNumber(st.text(0)) { credited.insert(d) } }
            st.finalize()
        }
        if credited.isEmpty { return false }
        var picked = Set<Int>()
        if let st = try? c.prepare("SELECT day FROM zone_pick;") {
            while st.step() { picked.insert(st.int(0)) }
            st.finalize()
        }
        // A pick may legitimately credit nothing — that day could have gained a real
        // offset since — but a credit with no pick behind it is always wrong.
        return !credited.subtracting(picked).isEmpty
    }

    /// Record a choice and re-resolve, so it propagates to neighbouring days at once.
    /// Still nothing written outside the catalog.
    func choose(day: Int, offset: String?) {
        guard let c = catalog, !progress.running else { return }
        snapshotForUndo(offset == nil ? "Take back a timezone" : "Choose a timezone")
        try? c.transaction {
            if let offset {
                let st = try c.prepare("INSERT OR REPLACE INTO zone_pick(day, utc_offset, chosen_at) VALUES(?,?,?);")
                st.bind(1, day).bind(2, offset).bind(3, Date().timeIntervalSince1970).done()
                st.finalize()
            } else {
                let st = try c.prepare("DELETE FROM zone_pick WHERE day = ?;")
                st.bind(1, day).done(); st.finalize()
            }
        }
        reresolve()
    }

    var pickCount: Int { catalog?.scalarInt("SELECT COUNT(*) FROM zone_pick;") ?? 0 }

    /// Re-run stage 4 only. Fingerprints are unaffected by a timezone choice, so
    /// there is no reason to make the person wait for a full pass.
    func reresolve() {
        guard let c = catalog, task == nil else { return }
        progress = Progress(stage: "resolving", running: true)
        task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.resolveAll(c)
            await MainActor.run {
                self.progress.running = false
                self.progress.stage = "done"
                self.task = nil
                self.refreshStats(); self.refreshBreakdown(); self.loadGroups()
                self.loadBallots(); self.loadDecisions(); self.loadAudit(); self.loadFill()
                if self.tab == .dials { self.loadDialPreviews() }
            }
        }
    }

    // MARK: decisions

    func loadDecisions() {
        guard let c = catalog else { return }
        let (rows, total) = Decisions.list(c, decisionFilter)
        decisionRows = rows; decisionTotal = total
        // A selection outside the filtered list is kept: `inspect` jumps straight to
        // an asset, and the detail loads it by id whether or not the list shows it.
        if decisionSelection == nil { decisionSelection = rows.first?.id }
    }

    /// One asset's full chain. A handful of indexed queries — cheap enough per click.
    func asset(_ clusterID: Int) -> Decisions.Asset? {
        guard let c = catalog else { return nil }
        return Decisions.load(c, cluster: clusterID)
    }

    /// Jump from anywhere to the chain for one asset.
    func inspect(_ clusterID: Int) {
        decisionSelection = clusterID
        advanced = true
        tab = .decisions
    }

    // MARK: boundary cases

    struct ReviewPair: Identifiable {
        struct Side { let id: Int; let path: String; let w: Int; let h: Int; let bytes: Int; let capturedAt: String? }
        let a: Side, b: Side
        let distance: Int
        let outcome: Clusterer.Pair.Outcome
        let maeHi: Double?, maeLo: Double?
        var id: String { "\(a.id)-\(b.id)" }
        var decided: Bool { outcome == .youSame || outcome == .youDifferent }
    }

    /// Pairs the machine would not decide, and pairs a person already has.
    @Published var reviewPairs: [ReviewPair] = []

    func loadReview() {
        guard let c = catalog else { return }
        var out: [ReviewPair] = []
        if let st = try? c.prepare("""
            SELECT p.a, p.b, p.distance, p.outcome, p.mae_hi, p.mae_lo,
                   fa.path, fa.width, fa.height, fa.size, fa.captured_at,
                   fb.path, fb.width, fb.height, fb.size, fb.captured_at
            FROM pair p JOIN file fa ON fa.id = p.a JOIN file fb ON fb.id = p.b
            WHERE p.outcome IN ('variant', 'youSame', 'youDifferent')
            ORDER BY CASE p.outcome WHEN 'variant' THEN 0 ELSE 1 END, p.mae_hi;
            """) {
            while st.step() {
                guard let o = Clusterer.Pair.Outcome(rawValue: st.text(3) ?? "") else { continue }
                out.append(ReviewPair(
                    a: .init(id: st.int(0), path: st.text(6) ?? "", w: st.int(7), h: st.int(8),
                             bytes: st.int(9), capturedAt: st.text(10)),
                    b: .init(id: st.int(1), path: st.text(11) ?? "", w: st.int(12), h: st.int(13),
                             bytes: st.int(14), capturedAt: st.text(15)),
                    distance: st.int(2), outcome: o,
                    maeHi: st.isNull(4) ? nil : st.double(4),
                    maeLo: st.isNull(5) ? nil : st.double(5)))
            }
            st.finalize()
        }
        reviewPairs = out
    }

    /// Keep `file` for this group — or, with nil, go back to the app's own choice.
    func keep(_ file: Int?, in group: Group) {
        guard let c = catalog, !progress.running else { return }
        snapshotForUndo("Choose the copy to keep")
        Pipeline.keep(c, file, siblings: group.files.map(\.id))
        regroup()
    }

    /// Record a verdict (or withdraw it with `nil`) and regroup at once.
    func decide(_ pair: ReviewPair, same: Bool?) {
        debugLog("decide \(pair.id) same=\(String(describing: same)) running=\(progress.running)")
        guard let c = catalog, !progress.running else { return }
        snapshotForUndo(same == nil ? "Undo a verdict" : same! ? "Treat as one photo" : "Keep as separate photos")
        Pipeline.decide(c, pair.a.id, pair.b.id, same: same)
        regroup()
    }

    /// Group and resolve again without rescanning: fingerprints are unaffected by
    /// a verdict or a dial, so there is no reason to make anyone wait for a scan.
    func regroup() {
        guard let c = catalog, task == nil else { return }
        refreshSources()
        progress = Progress(stage: "grouping", running: true)
        notice = nil
        task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.cluster(c)
            await self.resolveAll(c)
            await MainActor.run {
                self.progress.running = false
                self.progress.stage = "done"
                self.task = nil
                self.refreshStats(); self.refreshBreakdown(); self.loadGroups()
                self.loadBallots(); self.loadDecisions(); self.loadReview(); self.loadAudit(); self.loadFill(); self.loadTidy()
                if self.tab == .dials { self.loadDialPreviews() }
            }
        }
    }

    // MARK: dials, previewed before applied (PLAN §8)

    static let radiusChoices = [0, 2, 4, 6, 8]
    @Published var radiusPreview: Preview.RadiusResult?
    @Published var draftParams = Resolver.Params()
    @Published var placePreview: Preview.PlaceResult?
    private var previewInputs: [Resolver.Input] = []
    private var previewCurrent: [Resolver.Resolved] = []
    private var previewPicks: [Int: String] = [:]
    private var placeTask: Task<Void, Never>?

    /// Load what the previews need, once per visit to Dials. Nothing is written.
    func loadDialPreviews() {
        guard let c = catalog, !progress.running else { return }
        draftParams = params
        radiusPreview = nil; placePreview = nil
        Task.detached(priority: .userInitiated) { [weak self] in
            let inputs = Pipeline.claims(c)
            let picks = Pipeline.picks(c)
            let current = Resolver.resolve(inputs, picks: picks, params: Pipeline.params(c)).out
            await MainActor.run {
                self?.previewInputs = inputs; self?.previewCurrent = current; self?.previewPicks = picks
                self?.previewPlaces()
            }
            let items = Pipeline.imageItems(c)
            let pv = Preview.radii(items, Engine.radiusChoices, decisions: Pipeline.decisions(c, items))
            await MainActor.run { self?.radiusPreview = pv }
        }
    }

    /// Re-run on every change of a place dial; the latest one wins.
    func previewPlaces() {
        placeTask?.cancel()
        let (inputs, current, picks, draft) = (previewInputs, previewCurrent, previewPicks, draftParams)
        guard !inputs.isEmpty else { return }
        placeTask = Task.detached(priority: .userInitiated) { [weak self] in
            let r = Preview.places(inputs, picks: picks, current: current, candidate: draft)
            if Task.isCancelled { return }
            await MainActor.run { self?.placePreview = r }
        }
    }

    func applyRadius(_ r: Int) {
        guard r != radius else { return }
        snapshotForUndo("Change matching")
        radius = r
        regroup()
    }

    func applyPlaces() {
        guard let c = catalog, draftParams != params else { return }
        snapshotForUndo("Change place settings")
        Pipeline.setParams(c, draftParams)
        params = draftParams
        reresolve()
    }

    /// Paths for sample thumbnails — single indexed lookups.
    func path(file id: Int) -> String? {
        guard let c = catalog, let st = try? c.prepare("SELECT path FROM file WHERE id = ?;") else { return nil }
        defer { st.finalize() }
        st.bind(1, id)
        return st.step() ? st.text(0) : nil
    }
    func path(cluster id: Int) -> String? {
        guard let c = catalog, let st = try? c.prepare(
            "SELECT f.path FROM member m JOIN file f ON f.id = m.file_id WHERE m.cluster_id = ? AND m.role = 'canonical';")
        else { return nil }
        defer { st.finalize() }
        st.bind(1, id)
        return st.step() ? st.text(0) : nil
    }

    // MARK: writing a merged copy (ROADMAP v1.1)

    @Published var outputRoot: String?
    @Published var actOptions = Act.Options()
    @Published var actSummary: Act.Summary?
    @Published var actReport: Act.Report?
    @Published var actError: String?
    @Published var writtenCount = 0

    func loadAct() {
        guard let c = catalog else { return }
        outputRoot = c.setting("output_root").map(Act.canonicalRoot)
        if let j = c.setting("act_options"), let o = try? JSONDecoder().decode(Act.Options.self, from: Data(j.utf8)) {
            actOptions = o
        }
        refreshActSummary()
    }

    func refreshActSummary() {
        guard let c = catalog else { return }
        let opts = actOptions
        writtenCount = outputRoot.map { r in
            c.scalarInt("SELECT COUNT(*) FROM output WHERE state='verified' AND root='\(r.replacingOccurrences(of: "'", with: "''"))';")
        } ?? 0
        actError = nil
        if let r = outputRoot {
            do {
                try Act.check(c, root: r)
                let (need, free) = Act.space(c, root: r)
                if need > free { throw Act.Refusal.noSpace(need: need, free: free) }
            } catch { actError = "\(error)" }
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            let sm = Act.summary(c, options: opts)
            await MainActor.run { self?.actSummary = sm }
        }
    }

    func setActOptions(_ o: Act.Options) {
        actOptions = o
        if let c = catalog, let d = try? JSONEncoder().encode(o) { c.setSetting("act_options", String(decoding: d, as: UTF8.self)) }
        refreshActSummary()
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose an empty folder for the merged copy. It must not be inside a folder you are analysing."
        guard panel.runModal() == .OK, let url = panel.url, let c = catalog else { return }
        outputRoot = Act.canonicalRoot(url.path)
        c.setSetting("output_root", outputRoot!)
        refreshActSummary()
    }

    func startWrite() {
        guard let c = catalog, let root = outputRoot, task == nil, actError == nil else { return }
        progress = Progress(stage: "writing", running: true)
        notice = nil; actReport = nil
        stop = Ingest.Stop()
        let (stop, opts) = (self.stop, actOptions)
        task = Task.detached(priority: .userInitiated) { [weak self] in
            var report: Act.Report? = nil
            var err: String? = nil
            do {
                report = try Act.run(c, root: root, options: opts, workers: Engine.workers, stop: stop) { d, t in
                    Task { @MainActor in self?.progress.done = d; self?.progress.total = t }
                }
            } catch { err = "\(error)" }
            await MainActor.run {
                guard let self else { return }
                self.progress.running = false
                self.progress.stage = stop.isSet ? "cancelled" : "written"
                self.task = nil
                self.actReport = report; self.actError = err
                if let r = report {
                    self.notice = "Wrote \(r.written) verified file\(r.written == 1 ? "" : "s") to \((root as NSString).lastPathComponent)"
                        + (r.failed > 0 ? " — \(r.failed) could not be written" : "")
                        + ". Your originals were not touched."
                }
                self.refreshActSummary()
            }
        }
    }

    /// Remove the merged copy — only files still exactly as written.
    func undoWrite() {
        guard let c = catalog, let root = outputRoot else { return }
        // a run still going (the rescan Tidy starts, say) is waited for, not ignored
        if task != nil { Task { @MainActor in await self.whenIdle(); self.undoWrite() }; return }
        progress = Progress(stage: "removing", running: true)
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let u = Act.undo(c, root: root) { d, t in Task { @MainActor in self?.progress.done = d; self?.progress.total = t } }
            await MainActor.run {
                guard let self else { return }
                self.progress.running = false; self.progress.stage = "done"; self.task = nil
                self.notice = "Removed \(u.removed) written file\(u.removed == 1 ? "" : "s")"
                    + (u.keptChanged > 0 ? "; kept \(u.keptChanged) you have changed since" : "") + ". Originals untouched."
                self.actReport = nil
                self.refreshActSummary()
            }
        }
    }

    // MARK: undo — one history for every choice

    let undoManager: UndoManager = {
        let u = UndoManager(); u.levelsOfUndo = 50; return u
    }()
    @Published var undoTick = 0      // republishes menu titles after undo/redo

    /// Call before any action that changes a decision. Undo restores exactly this.
    func snapshotForUndo(_ name: String) {
        guard let c = catalog else { return }
        guard let before = try? Snapshot.take(c) else {
            notice = "Could not record the state before “\(name)”, so ⌘Z will not undo it. The catalog may be locked or full."
            return
        }
        undoManager.registerUndo(withTarget: self) { eng in eng.restore(before, name: name) }
        undoManager.setActionName(name)
        undoTick += 1
    }

    private func restore(_ snap: Snapshot, name: String) {
        guard let c = catalog else { return }
        if let now = try? Snapshot.take(c) {
            undoManager.registerUndo(withTarget: self) { eng in eng.restore(now, name: name) }  // becomes redo
        }
        undoManager.setActionName(name)
        snap.apply(c)
        params = Pipeline.params(c); radius = Pipeline.radius(c)
        loadAcks(); loadRules(); refreshSources(); loadAct()
        undoTick += 1
        notice = "Undid: \(name)"
        // wait for a run in progress, then rebuild what the decisions produce
        if task == nil { regroup() } else {
            Task { @MainActor in
                while self.task != nil { try? await Task.sleep(nanoseconds: 200_000_000) }
                self.regroup()
            }
        }
    }

    /// Until the running task, if any, has finished (review round 2, R13).
    func whenIdle() async {
        while task != nil { try? await Task.sleep(nanoseconds: 200_000_000) }
    }

    // MARK: tidy in place

    @Published var tidyPlan = Tidy.Plan()
    @Published var tidied = 0

    func loadTidy() {
        guard let c = catalog else { return }
        tidyPlan = Tidy.plan(c)
        tidied = c.scalarInt("SELECT COUNT(*) FROM trashed;")
    }

    /// Tidy reads every duplicate and its kept copy to be sure of them; on a real
    /// library that is minutes of disk work, so it runs off the main actor with
    /// progress, and the window stays alive (review finding 8).
    func tidy() {
        guard let c = catalog, task == nil else { return }
        progress = Progress(stage: "tidying", running: true)
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let r = Tidy.run(c) { d, t in Task { @MainActor in self?.progress.done = d; self?.progress.total = t } }
            await MainActor.run {
                guard let self else { return }
                self.progress.running = false; self.progress.stage = "done"; self.task = nil
                self.notice = "Moved \(r.moved) extra cop\(r.moved == 1 ? "y" : "ies") (\(byteString(r.bytes))) to the Trash"
                    + (r.skipped > 0 ? "; left \(r.skipped) that had changed" : "") + ". ⌘Z puts them back."
                if r.moved > 0 {
                    self.undoManager.registerUndo(withTarget: self) { eng in eng.putBack() }
                    self.undoManager.setActionName("Move duplicates to the Trash")
                    self.undoTick += 1
                }
                self.loadTidy()
                self.analyse()        // the moved files are gone from their folders: rescan and regroup
            }
        }
    }

    func putBack() {
        guard let c = catalog else { return }
        if task != nil { Task { @MainActor in await self.whenIdle(); self.putBack() }; return }
        progress = Progress(stage: "restoring", running: true)
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let r = Tidy.restore(c)
            await MainActor.run {
                guard let self else { return }
                self.progress.running = false; self.progress.stage = "done"; self.task = nil
                self.notice = "Put back \(r.restored) cop\(r.restored == 1 ? "y" : "ies")"
                    + (r.occupied > 0 ? "; \(r.occupied) could not go back because a file now has that name" : "")
                    + (r.missing > 0 ? "; \(r.missing) were no longer in the Trash" : "") + "."
                self.loadTidy()
                self.analyse()
            }
        }
    }

    // MARK: the guided path

    @Published var step: Guide.Step = .add
    /// The advanced panes — everything the guided path simplifies away.
    @Published var advanced: Bool = Engine.initialAdvanced {
        didSet { if !Engine.modeOverridden { UserDefaults.standard.set(advanced, forKey: "advanced") } }
    }
    /// dev aid: `open -g --env PM_ADVANCED=0 …` shows a mode for one launch without
    /// touching the person's saved preference.
    private static let modeOverridden = ProcessInfo.processInfo.environment["PM_ADVANCED"] != nil
    private static var initialAdvanced: Bool {
        if let v = ProcessInfo.processInfo.environment["PM_ADVANCED"] { return v == "1" }
        return UserDefaults.standard.bool(forKey: "advanced")
    }
    @Published var acks: [String: String] = [:]
    @Published var missing = (either: 0, date: 0, place: 0)

    var guideInputs: Guide.Inputs {
        var i = Guide.Inputs()
        i.duplicates = stats.duplicates; i.wastedBytes = stats.wastedBytes
        i.editedCopies = reviewPairs.filter { !$0.decided }.count
        i.wrongZones = audit.count
        i.wrongZoneDays = audit.filter { $0.before.prefix(10) != $0.after.prefix(10) }.count
        i.unclearDays = ballots.count
        i.missingEither = missing.either; i.missingDate = missing.date; i.missingPlace = missing.place
        i.unreadable = sourceInfo.reduce(0) { $0 + $1.unreadable }
        i.unavailableSources = sourceInfo.filter { !$0.available }.count
        return i
    }
    var cards: [Guide.Card] { Guide.cards(guideInputs) }
    func isDone(_ c: Guide.Card) -> Bool { acks[c.kind.rawValue] == c.signature }
    var openCards: [Guide.Card] { cards.filter { !isDone($0) } }

    /// Edited copies the person has not yet said same or different about.
    var undecidedEdits: Int { reviewPairs.filter { !$0.decided }.count }
    /// Time & place is settled when nothing lacks a date or place, or the person
    /// chose to leave the rest — a choice that lapses if the set of them changes.
    var missingSettled: Bool { !openCards.contains { $0.kind == .missing } }
    func skipMissing() { if let c = cards.first(where: { $0.kind == .missing }) { acknowledge(c) } }
    func lookAgainAtMissing() { if let c = cards.first(where: { $0.kind == .missing }) { reopen(c) } }

    func loadAcks() {
        guard let c = catalog, let st = try? c.prepare("SELECT key, value FROM setting WHERE key LIKE 'ack.%';") else { return }
        var out: [String: String] = [:]
        while st.step() { out[String((st.text(0) ?? "").dropFirst(4))] = st.text(1) }
        st.finalize()
        acks = out
    }

    func acknowledge(_ card: Guide.Card) {
        guard let c = catalog else { return }
        snapshotForUndo("Mark “\(card.title)” as done")
        c.setSetting("ack." + card.kind.rawValue, card.signature)
        acks[card.kind.rawValue] = card.signature
    }

    func reopen(_ card: Guide.Card) {
        guard let c = catalog else { return }
        try? c.transaction {
            let st = try c.prepare("DELETE FROM setting WHERE key = ?;")
            st.bind(1, "ack." + card.kind.rawValue).done(); st.finalize()
        }
        acks[card.kind.rawValue] = nil
    }

    /// "Keep them all": say *different* to every edited copy still undecided.
    func keepAllSeparate() {
        guard let c = catalog, !progress.running else { return }
        snapshotForUndo("Keep edited copies separate")
        for p in reviewPairs where !p.decided { Pipeline.decide(c, p.a.id, p.b.id, same: false) }
        regroup()
    }

    // MARK: fill in by hand

    @Published var fillFilter: Manual.Filter = .attention
    @Published var fillRows: [Manual.Row] = []
    @Published var recentPlaces: [(lat: Double, lon: Double, uses: Int)] = []

    /// Photographs whose place the app worked out, gathered by area (50 km), for
    /// accepting as a group once the odd ones out have been fixed by hand.
    struct PlaceGroup: Identifiable {
        let id: Int
        let lat: Double, lon: Double
        let rows: [Manual.Row]
        var label: String { placeLabel(lat, lon) }
        var span: String {
            let ts = rows.compactMap(\.localTime).sorted()
            guard let a = ts.first, let b = ts.last else { return "" }
            let da = pretty(a).components(separatedBy: ",")[0], db = pretty(b).components(separatedBy: ",")[0]
            return da == db ? da : "\(da) – \(db)"
        }
        /// "same day, same place ×8 · nearest fix ×2"
        var how: String {
            var tally: [String: Int] = [:]
            for r in rows {
                let k = r.placeSource.hasPrefix("nearest fix") ? "a nearby photo" : r.placeSource.hasPrefix("same folder") ? "the same folder" : "the same day"
                tally[k, default: 0] += 1
            }
            return tally.sorted { $0.value > $1.value }.map { "from \($0.key) ×\($0.value)" }.joined(separator: " · ")
        }
    }
    @Published var placeGroups: [PlaceGroup] = []
    var workedOutPlaces: Int { placeGroups.reduce(0) { $0 + $1.rows.count } }

    func loadFill() {
        guard let c = catalog else { return }
        fillRows = Manual.rows(c, fillFilter)
        placeGroups = Manual.areas(Manual.rows(c, .workedOut)).enumerated().map { i, g in
            let n = Double(g.count)
            return PlaceGroup(id: i, lat: g.reduce(0) { $0 + ($1.lat ?? 0) } / n, lon: g.reduce(0) { $0 + ($1.lon ?? 0) } / n, rows: g)
        }
        let base = "FROM resolution r WHERE "
        missing = (c.scalarInt("SELECT COUNT(*) \(base)\(Manual.Filter.either.sql);"),
                   c.scalarInt("SELECT COUNT(*) \(base)\(Manual.Filter.date.sql);"),
                   c.scalarInt("SELECT COUNT(*) \(base)\(Manual.Filter.place.sql);"))
        var rp: [(Double, Double, Int)] = []
        if let st = try? c.prepare("""
            SELECT lat, lon, COUNT(*) FROM manual_fact WHERE lat IS NOT NULL
            GROUP BY round(lat, 5), round(lon, 5) ORDER BY MAX(set_at) DESC LIMIT 6;
            """) {
            while st.step() { rp.append((st.double(0), st.double(1), st.int(2))) }
            st.finalize()
        }
        recentPlaces = rp.map { (lat: $0.0, lon: $0.1, uses: $0.2) }
    }

    /// Enter a day and/or a place for many photographs at once.
    func fill(_ clusters: [Int], day: Date?, place: (lat: Double, lon: Double)?) {
        guard let c = catalog, !progress.running, !clusters.isEmpty, day != nil || place != nil else { return }
        snapshotForUndo("Fill in \(clusters.count) photo\(clusters.count == 1 ? "" : "s")")
        var dayString: String? = nil
        if let day {
            let comps = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: day)
            dayString = String(format: "%04d:%02d:%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
        }
        Manual.set(c, clusters: clusters, day: dayString, lat: place?.lat, lon: place?.lon)
        notice = "Filled in \(clusters.count) photograph\(clusters.count == 1 ? "" : "s")"
            + [dayString.map { " — " + pretty($0 + " 12:00:00").components(separatedBy: ",")[0] },
               place.map { " at " + placeLabel($0.lat, $0.lon) }].compactMap { $0 }.joined()
            + ". Nothing on disk has changed."
        reresolve()
    }

    /// Accept the places worked out for these photographs, as they stand now.
    func confirmPlaces(_ rows: [Manual.Row]) {
        guard let c = catalog, !progress.running, !rows.isEmpty else { return }
        snapshotForUndo("Accept \(rows.count) worked-out place\(rows.count == 1 ? "" : "s")")
        Manual.confirm(c, places: rows.compactMap { r in r.lat.flatMap { la in r.lon.map { (cluster: r.id, lat: la, lon: $0) } } })
        notice = "Accepted the place worked out for \(rows.count) photograph\(rows.count == 1 ? "" : "s"). Nothing on disk has changed; ⌘Z takes it back."
        reresolve()
    }

    func clearFill(_ clusters: [Int], day: Bool, place: Bool) {
        guard let c = catalog, !progress.running, !clusters.isEmpty else { return }
        snapshotForUndo("Clear what was filled in")
        Manual.set(c, clusters: clusters, clearDay: day, clearPlace: place)
        reresolve()
    }

    // MARK: place rules

    @Published var placeRules: [Resolver.PlaceRule] = []
    func loadRules() { if let c = catalog { placeRules = Pipeline.rules(c) } }

    /// Use one located photograph's place for the unlocated ones in its folder, or
    /// between two days.
    func addRule(from asset: Decisions.Asset, folder: String?, from d0: Int?, to d1: Int?) {
        guard let c = catalog, let r = asset.resolution, let la = r.lat, let lo = r.lon else { return }
        snapshotForUndo("Add a place rule")
        let when = d0.map { a in
            let b = d1 ?? a
            return a == b ? Resolver.dayLabel(a) : "\(Resolver.dayLabel(a)) – \(Resolver.dayLabel(b))"
        }
        let label = [folder.map { "“\($0)”" }, when].compactMap { $0 }.joined(separator: ", ")
            + " — where \(asset.canonical?.name ?? "a photograph") was taken"
        Pipeline.addRule(c, folder: folder, from: d0, to: d1, lat: la, lon: lo, label: label)
        loadRules(); reresolve()
    }

    func deleteRule(_ id: Int) {
        guard let c = catalog else { return }
        snapshotForUndo("Remove a place rule")
        Pipeline.deleteRule(c, id); loadRules(); reresolve()
    }

    // MARK: timeline

    struct MonthRow: Identifiable {
        let month: String            // "2019-07"
        let read: Int, worked: Int, unknown: Int
        var id: String { month }
        var total: Int { read + worked + unknown }
        var date: Date {
            var c = DateComponents(); c.year = Int(month.prefix(4)); c.month = Int(month.suffix(2)); c.day = 15
            return Calendar(identifier: .gregorian).date(from: c) ?? Date()
        }
    }
    @Published var months: [MonthRow] = []

    func loadTimeline() {
        guard let c = catalog else { return }
        var out: [MonthRow] = []
        let worked = """
            (time_source LIKE 'mtime%' OR time_source LIKE '%date only%'
             OR zone_source IN ('from a nearby photo''s own offset','nearest dated photo','nearest photo in time'))
            """
        if let st = try? c.prepare("""
            SELECT substr(replace(local_time, ':', '-'), 1, 7) AS m,
                   SUM(utc_offset IS NOT NULL AND NOT \(worked)),
                   SUM(utc_offset IS NOT NULL AND \(worked)),
                   SUM(utc_offset IS NULL)
            FROM resolution WHERE local_time IS NOT NULL AND local_time >= '1990'
            GROUP BY m ORDER BY m;
            """) {
            while st.step() {
                out.append(MonthRow(month: st.text(0) ?? "", read: st.int(1), worked: st.int(2), unknown: st.int(3)))
            }
            st.finalize()
        }
        months = out
    }

    // MARK: checks — contradictions in the result (Audit)

    struct AuditRow: Identifiable {
        let finding: Audit.Finding
        let path: String
        let before: String, after: String       // local clock now, and once corrected
        var id: String { finding.id }
    }
    @Published var audit: [AuditRow] = []
    @Published var corrected = 0

    func loadAudit() {
        guard let c = catalog else { return }
        loadTimeline()
        Task.detached(priority: .utility) { [weak self] in
            let res = Resolver.resolve(Pipeline.claims(c), picks: Pipeline.picks(c),
                                       params: Pipeline.params(c), fixes: Pipeline.fixes(c), rules: Pipeline.rules(c), manual: Manual.load(c)).out
            var byID: [Int: Resolver.Resolved] = [:]
            for r in res { byID[r.clusterID] = r }
            var paths: [Int: String] = [:]
            if let st = try? c.prepare("SELECT m.cluster_id, f.path FROM member m JOIN file f ON f.id=m.file_id WHERE m.role='canonical';") {
                while st.step() { paths[st.int(0)] = st.text(1) }
                st.finalize()
            }
            let rows: [AuditRow] = Audit.zones(res).compactMap { f in
                guard let r = byID[f.clusterID], let t = r.localTime, let i = r.instant else { return nil }
                return AuditRow(finding: f, path: paths[f.clusterID] ?? "", before: t,
                                after: Resolver.wallClock(i, offset: Resolver.offsetSeconds(f.expected)))
            }
            let n = res.filter { $0.zoneSource == "you corrected it" }.count
            await MainActor.run { self?.audit = rows; self?.corrected = n }
        }
    }

    /// Correct these photographs to the offset their surroundings record: the moment
    /// stands and the clock moves — or, with `keepClock`, the clock stands and the
    /// moment moves, for a camera that showed local time under a wrongly stamped zone.
    func correct(_ rows: [AuditRow], keepClock: Bool = false) {
        guard let c = catalog, !progress.running else { return }
        snapshotForUndo(rows.count == 1 ? "Correct a time zone" : "Correct \(rows.count) time zones")
        Pipeline.fix(c, rows.map { ($0.finding.clusterID, $0.finding.expected) }, keepClock: keepClock)
        reresolve()
    }

    func undoCorrections() {
        guard let c = catalog, !progress.running else { return }
        snapshotForUndo("Remove corrections")
        try? c.transaction { try c.run("DELETE FROM zone_fix;") }
        reresolve()
    }

    // MARK: export

    /// A one-line result shown in the status bar until the next run.
    @Published var notice: String?

    func exportFindings() {
        guard let c = catalog, stats.assets > 0 else { return }
        let panel = NSSavePanel()
        panel.title = "Export findings"
        panel.message = "One row per photograph: the copy kept, its duplicates, and where each date, timezone and place came from."
        panel.nameFieldStringValue = "PhotoMerge findings.csv"
        panel.allowedContentTypes = [.commaSeparatedText, .json]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let asJSON = url.pathExtension.lowercased() == "json"
        Task.detached(priority: .userInitiated) { [weak self] in
            let recs = Export.records(c)
            let result: String
            do {
                let data = asJSON ? try Export.json(recs) : Data(Export.csv(recs).utf8)
                try data.write(to: url, options: .atomic)
                result = "Exported \(recs.count) photographs to \(url.lastPathComponent)."
            } catch {
                result = "Export failed: \(error.localizedDescription)"
            }
            await MainActor.run { self?.notice = result }
        }
    }

    // MARK: reads for the UI

    struct Group: Identifiable {
        let id: Int
        let method: String
        let size: Int
        let wasted: Int
        var localTime: String?
        var timeSource: String?
        var utcOffset: String?
        var zoneSource: String?
        var lat: Double?
        var lon: Double?
        var placeSource: String?
        var files: [FileRow] = []
    }
    struct FileRow: Identifiable {
        let id: Int
        let path: String
        let role: String
        let reason: String?
        let w: Int, h: Int, bytes: Int
    }

    /// The survey for one source: what is in it, and how far reading it has got.
    struct SourceInfo: Identifiable {
        let id: Int
        let path: String
        var files = 0, images = 0, videos = 0, bytes = 0
        var unread = 0, unreadable = 0
        var unrecognised = 0                 // files that are not a photo or video the app reads
        var unrecognisedKinds = ""           // "avi ×3, mkv ×1"
        var earliest: String?, latest: String?
        var available = true
        var exclude = ""
    }
    @Published var sourceInfo: [SourceInfo] = []

    func refreshSources() {
        guard let c = catalog else { return }
        var out: [SourceInfo] = []
        if let st = try? c.prepare("""
            SELECT s.id, s.path, COUNT(f.id),
                   COALESCE(SUM(f.kind='image'),0), COALESCE(SUM(f.kind='video'),0),
                   COALESCE(SUM(f.size),0), COALESCE(SUM(f.state='scanned'),0),
                   COALESCE(SUM(f.state='failed'),0),
                   MIN(CASE WHEN f.captured_at >= '1990' THEN f.captured_at END), MAX(f.captured_at),
                   COALESCE(s.exclude, ''), COALESCE(s.unrecognised, 0), COALESCE(s.unrecognised_kinds, '')
            FROM source s LEFT JOIN file f ON f.source_id = s.id
            GROUP BY s.id ORDER BY s.id;
            """) {
            while st.step() {
                var i = SourceInfo(id: st.int(0), path: st.text(1) ?? "")
                i.files = st.int(2); i.images = st.int(3); i.videos = st.int(4); i.bytes = st.int(5)
                i.unread = st.int(6); i.unreadable = st.int(7)
                i.earliest = st.text(8); i.latest = st.text(9); i.exclude = st.text(10) ?? ""
                i.unrecognised = st.int(11); i.unrecognisedKinds = st.text(12) ?? ""
                var dir: ObjCBool = false
                i.available = FileManager.default.fileExists(atPath: i.path, isDirectory: &dir) && dir.boolValue
                out.append(i)
            }
            st.finalize()
        }
        sourceInfo = out
        sources = out.map(\.path)
    }

    /// Save what to leave out of a source. Applied by the next scan, which forgets
    /// anything already read that now matches.
    func setExclusions(_ id: Int, _ text: String) {
        guard let c = catalog else { return }
        snapshotForUndo("Change exclusions")
        try? c.transaction {
            let st = try c.prepare("UPDATE source SET exclude = ? WHERE id = ?;")
            st.bind(1, text.isEmpty ? nil : text).bind(2, id).done(); st.finalize()
        }
        refreshSources()
    }

    /// Forget one source and everything read from it, then regroup what remains.
    /// The folder itself is not touched.
    func removeSource(_ id: Int) {
        guard let c = catalog, !progress.running else { return }
        try? c.transaction {
            let st = try c.prepare("DELETE FROM source WHERE id = ?;")
            st.bind(1, id).done(); st.finalize()
        }
        refreshSources()
        regroup()
    }

    func refreshStats() {
        guard let c = catalog else { return }
        var s = Stats()
        s.files     = c.scalarInt("SELECT COUNT(*) FROM file;")
        s.images    = c.scalarInt("SELECT COUNT(*) FROM file WHERE kind='image';")
        s.videos    = c.scalarInt("SELECT COUNT(*) FROM file WHERE kind='video';")
        s.assets    = c.scalarInt("SELECT COUNT(*) FROM cluster;")
        s.duplicates = c.scalarInt("SELECT COUNT(*) FROM member WHERE role='duplicate';")
        s.wastedBytes = c.scalarInt("SELECT COALESCE(SUM(wasted),0) FROM cluster;")
        // from `resolution` — what the resolver decided, not what a file happened to claim
        s.dated   = c.scalarInt("SELECT COUNT(*) FROM resolution WHERE local_time IS NOT NULL;")
        s.zoned   = c.scalarInt("SELECT COUNT(*) FROM resolution WHERE utc_offset IS NOT NULL;")
        s.located = c.scalarInt("SELECT COUNT(*) FROM resolution WHERE lat IS NOT NULL;")
        s.inferredPlace = c.scalarInt("SELECT COUNT(*) FROM resolution WHERE place_source NOT IN ('measured','sidecar GPS','none');")
        s.guessedTime   = c.scalarInt("SELECT COUNT(*) FROM resolution WHERE time_source LIKE 'mtime%';")
        stats = s
    }

    /// How each place was arrived at, for the Dates & places pane.
    @Published var placeBreakdown: [(String, Int)] = []

    func refreshBreakdown() {
        guard let c = catalog else { return }
        var rows: [(String, Int)] = []
        if let st = try? c.prepare("""
            SELECT COALESCE(place_source,'none') AS s, COUNT(*) FROM resolution
            GROUP BY s ORDER BY COUNT(*) DESC;
            """) {
            while st.step() { rows.append((st.text(0) ?? "none", st.int(1))) }
            st.finalize()
        }
        placeBreakdown = rows
    }

    @Published var groupsTotal = 0     // all groups with a duplicate; `groups` shows the first `limit`
    func loadGroups(limit: Int = 300) {
        guard let c = catalog else { return }
        groupsTotal = c.scalarInt("SELECT COUNT(*) FROM cluster c WHERE EXISTS (SELECT 1 FROM member d WHERE d.cluster_id = c.id AND d.role = 'duplicate');")
        var out: [Group] = []
        if let st = try? c.prepare("""
            SELECT c.id, c.method, (SELECT COUNT(*) FROM member x WHERE x.cluster_id = c.id AND x.role IN ('canonical','duplicate')), c.wasted,
                   r.local_time, r.time_source, r.utc_offset, r.zone_source,
                   r.lat, r.lon, r.place_source
            FROM cluster c LEFT JOIN resolution r ON r.cluster_id = c.id
            WHERE EXISTS (SELECT 1 FROM member d WHERE d.cluster_id = c.id AND d.role = 'duplicate')
            ORDER BY c.wasted DESC LIMIT \(limit);
            """) {
            while st.step() {
                out.append(Group(id: st.int(0), method: st.text(1) ?? "",
                                 size: st.int(2), wasted: st.int(3),
                                 localTime: st.text(4), timeSource: st.text(5),
                                 utcOffset: st.text(6), zoneSource: st.text(7),
                                 lat: st.isNull(8) ? nil : st.double(8),
                                 lon: st.isNull(9) ? nil : st.double(9),
                                 placeSource: st.text(10)))
            }
            st.finalize()
        }
        for i in out.indices {
            var files: [FileRow] = []
            if let st = try? c.prepare("""
                SELECT f.id, f.path, m.role, m.reason, f.width, f.height, f.size
                FROM member m JOIN file f ON f.id = m.file_id
                WHERE m.cluster_id = \(out[i].id)
                ORDER BY CASE m.role WHEN 'canonical' THEN 0 ELSE 1 END, f.size DESC;
                """) {
                while st.step() {
                    files.append(FileRow(id: st.int(0), path: st.text(1) ?? "", role: st.text(2) ?? "",
                                         reason: st.text(3), w: st.int(4), h: st.int(5), bytes: st.int(6)))
                }
                st.finalize()
            }
            out[i].files = files
        }
        groups = out
    }
}
