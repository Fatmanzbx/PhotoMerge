import Foundation

/// Decides each photograph's capture time, timezone and place from what its files
/// claim, plus what the rest of the collection knows (PLAN §7.2, §7.3).
///
/// Order matters and is not arbitrary:
///   1. time   — a place cannot be inferred without knowing when
///   2. place  — from a measured fix, or the day's other fixes
///   3. zone   — from a MEASURED fix only; an inferred place may never certify one
///   4. re-anchor — a wall clock means nothing until its zone is known
enum Resolver {

    // MARK: inputs

    struct Input {
        let clusterID: Int
        var claims: [Claim] = []      // one per member file
    }
    struct Claim {
        var capturedAt: String?       // "YYYY:MM:DD HH:MM:SS" as recorded
        var utcOffset: String?        // "+08:00" if the file says so
        var lat: Double?
        var lon: Double?
        var mtime: Double             // filesystem, the weakest evidence there is
        var ev: Double? = nil         // exposure value, for the daylight signal
        var fileName: String? = nil   // an epoch-ms name is an absolute instant
        var model: String? = nil      // device habit

        // Evidence from outside the image itself (BUILDLOG §2.1, INHERITED §2.7).
        /// An absolute instant: a video container's creation date, a Takeout
        /// sidecar's photoTakenTime, a Pixel or epoch filename. Never a wall clock.
        var utcInstant: Double? = nil
        var utcSource: String? = nil
        /// A wall clock read from the filename — weaker than EXIF, far better than mtime.
        var nameLocal: String? = nil
        var nameRule: String? = nil
        /// GPS from a Takeout sidecar: the camera's fix, carried beside the file.
        var sidecarLat: Double? = nil
        var sidecarLon: Double? = nil
        /// The folder the file sits in, when it is not a Takeout wrapper.
        var album: String? = nil
    }

    /// Sources ranked by how directly they saw the capture.
    static let utcRank = ["video container": 0, "Takeout sidecar": 1,
                          "Pixel filename (UTC)": 2, "epoch filename (UTC)": 3]

    /// Evidence read off the files, as opposed to worked out from other photos.
    static func readZone(_ s: String) -> Bool { s == "tag" || s.hasPrefix("clock + ") || s == "you corrected it" }
    static func readPlace(_ s: String) -> Bool { s == "measured" || s == "sidecar GPS" }

    /// "YYYY:MM:DD HH:MM:SS" for an instant seen through an offset.
    static func wallClock(_ instant: Double, offset: Double) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                   from: Date(timeIntervalSince1970: instant + offset))
        return String(format: "%04d:%02d:%02d %02d:%02d:%02d", c.year ?? 0, c.month ?? 0,
                      c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// A wall clock and an instant of the same moment *are* its timezone. Rounded
    /// to the quarter hour; rejected if it is not a real offset.
    static func derivedOffset(local: String, instant: Double) -> Double? {
        guard let asUTC = epoch(local, "+00:00") else { return nil }
        let raw = asUTC - instant
        let q = (raw / 900).rounded() * 900
        guard abs(raw - q) <= 120, q >= -12 * 3600, q <= 14 * 3600 else { return nil }
        return q
    }

    /// A place a person gave: for a folder, a range of days, or both. Applied only to
    /// photographs nothing else could place (BUILDLOG §2.18, rule 4).
    struct PlaceRule: Equatable {
        var id: Int
        var folder: String?
        var dayFrom: Int?, dayTo: Int?
        var lat: Double, lon: Double
        var label: String
        func matches(folder f: String?, day: Int?) -> Bool {
            if let folder, folder != f { return false }
            if let a = dayFrom, let b = dayTo { guard let d = day, d >= a, d <= b else { return false } }
            return folder != nil || dayFrom != nil
        }
    }

    /// A day the resolver could not zone, with the ballot it would offer.
    struct DayBallot {
        var day: Int
        var dateLabel: String
        var photographs: Int
        var ballot: Ballot.Result
    }

    // MARK: outputs

    struct Resolved {
        var clusterID: Int
        var localTime: String?        // capture-local, the thing a viewer sees
        var timeSource: String = "none"
        var utcOffset: String?
        var zoneSource: String = "none"
        var lat: Double?
        var lon: Double?
        var placeSource: String = "none"
        /// Seconds since epoch, for ordering. Only meaningful once a zone is known.
        var instant: Double?
    }

    struct Stats {
        var dated = 0, zoned = 0, located = 0
        var timeFromExif = 0, timeFromMtime = 0
        var zoneFromTag = 0, zoneFromPlace = 0, zoneFromNeighbour = 0, zoneFromYou = 0
        var zoneDerived = 0, timeFromName = 0, timeFromInstant = 0, zoneCorrected = 0
        var timeEntered = 0, placeEntered = 0
        var placeMeasured = 0, placeFromDay = 0, placeFromNeighbour = 0
        var placeFromFolder = 0, declinedFolderSpansTooFar = 0, placeFromRule = 0
        var batchDowngraded = 0
        var declinedDaySpansTooFar = 0
    }

    // MARK: tunables (all dials in the UI eventually)

    static var earliestPlausibleYear = 1990
    /// The resolver's dials. A value, not globals, so the Dials pane can preview a
    /// setting on this collection without disturbing the stored result.
    struct Params: Equatable, Codable {
        var dayRadiusKM = 25.0             // "same day, same place"
        var travelMinutes = 60.0           // nearest-in-time bound
        var batchThreshold = 25            // identical timestamps ⇒ batch artifact
    }
    static var travelKMH = 100.0

    // MARK: time parsing

    /// Parses "YYYY:MM:DD HH:MM:SS" without a DateFormatter — this runs per file and
    /// DateFormatter is famously slow.
    static func parse(_ s: String?) -> (y: Int, mo: Int, d: Int, h: Int, mi: Int, sec: Int)? {
        guard let s, s.count >= 19 else { return nil }
        let c = Array(s.utf8)
        func num(_ a: Int, _ b: Int) -> Int? {
            var v = 0
            for i in a..<b {
                guard c[i] >= 48, c[i] <= 57 else { return nil }
                v = v * 10 + Int(c[i] - 48)
            }
            return v
        }
        guard let y = num(0, 4), let mo = num(5, 7), let d = num(8, 10),
              let h = num(11, 13), let mi = num(14, 16), let sec = num(17, 19)
        else { return nil }
        return (y, mo, d, h, mi, sec)
    }

    static func plausible(_ s: String?) -> Bool {
        guard let p = parse(s) else { return false }
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        return p.y >= earliestPlausibleYear && p.y <= year
            && (1...12).contains(p.mo) && (1...31).contains(p.d)
    }

    /// Days since 1970 for a civil date — enough for "same day" and day ordering,
    /// and it avoids a timezone question we have not answered yet.
    static func dayNumber(_ s: String?) -> Int? {
        guard let p = parse(s) else { return nil }
        var y = p.y, m = p.mo
        if m <= 2 { y -= 1; m += 12 }
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m - 3) + 2) / 5 + p.d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    static func secondsOfDay(_ s: String?) -> Int? {
        guard let p = parse(s) else { return nil }
        return p.h * 3600 + p.mi * 60 + p.sec
    }

    /// Local wall clock → epoch seconds. **Requires** an offset: treating an unknown
    /// zone as UTC invents an instant nobody chose, which is how a wall clock ends up
    /// silently six hours wrong (INHERITED §2.8). No zone, no instant — the photo
    /// still sorts correctly within its own day by local time.
    static func epoch(_ local: String?, _ offset: String?) -> Double? {
        guard offset != nil else { return nil }
        guard let day = dayNumber(local), let sod = secondsOfDay(local) else { return nil }
        return Double(day) * 86400 + Double(sod) - offsetSeconds(offset)
    }

    static func offsetSeconds(_ o: String?) -> Double {
        guard let o, o.count >= 6 else { return 0 }
        let sign: Double = o.hasPrefix("-") ? -1 : 1
        let parts = o.dropFirst().split(separator: ":")
        guard let h = Double(parts.first ?? "0") else { return 0 }
        let m = parts.count > 1 ? (Double(parts[1]) ?? 0) : 0
        return sign * (h * 3600 + m * 60)
    }

    static func offsetString(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        let sign = s < 0 ? "-" : "+"
        let a = abs(s)
        return String(format: "%@%02d:%02d", sign, a / 3600, (a % 3600) / 60)
    }

    // MARK: geography

    static func haversineKM(_ aLat: Double, _ aLon: Double, _ bLat: Double, _ bLon: Double) -> Double {
        let r = 6371.0, p = Double.pi / 180
        let dLat = (bLat - aLat) * p, dLon = (bLon - aLon) * p
        let s = sin(dLat / 2) * sin(dLat / 2)
              + cos(aLat * p) * cos(bLat * p) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(s)))
    }

    // MARK: the pass

    /// A day number back to a readable date.
    static func dayLabel(_ day: Int) -> String {
        var z = day + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe/1460 + doe/36524 - doe/146096) / 365
        let y0 = yoe + era * 400
        let doy = doe - (365 * yoe + yoe/4 - yoe/100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let y = m <= 2 ? y0 + 1 : y0
        let months = ["", "Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
        z = 0
        return "\(d) \(months[max(1, min(12, m))]) \(y)"
    }

    /// `picks` maps a day number to an offset the *user* chose from a ballot. A
    /// choice is the strongest evidence in the system — stronger than a tag, which
    /// can be wrong — so it is applied before any inference and then allowed to
    /// propagate to neighbouring days like any other known zone.
    /// `fixes` maps a cluster to an offset a person corrected it to. The instant is
    /// kept and the wall clock follows: the file's clock was right about *when*,
    /// wrong about *where on the globe that was* (Audit).
    static func resolve(_ inputs: [Input], picks: [Int: String] = [:],
                        params: Params = Params(), fixes: [Int: String] = [:],
                        rules: [PlaceRule] = [],
                        manual: [Int: Manual.Entry] = [:]) -> (out: [Resolved], stats: Stats) {
        var stats = Stats()
        var out: [Resolved] = []
        out.reserveCapacity(inputs.count)

        // ---- batch detection: a timestamp shared by very many files is an export
        // artifact, not a capture time (INHERITED §2.5).
        var seen: [String: Int] = [:]
        for i in inputs { for c in i.claims { if let t = c.capturedAt { seen[t, default: 0] += 1 } } }
        let batched = Set(seen.filter { $0.value >= params.batchThreshold }.keys)

        // ---- 1. time: earliest plausible EXIF claim wins (INHERITED §2.6); then a
        // filename's wall clock; then an absolute instant; the file date last.
        var utcOnly = Set<Int>()                        // indices awaiting a zone
        var pendingUTC: [Int: (u: Double, src: String)] = [:]
        for input in inputs {
            var r = Resolved(clusterID: input.clusterID)
            var best: String? = nil
            var bestOffset: String? = nil
            for c in input.claims {
                guard plausible(c.capturedAt), let t = c.capturedAt else { continue }
                if batched.contains(t) { stats.batchDowngraded += 1; continue }
                if best == nil || t < best! { best = t; bestOffset = c.utcOffset }
            }
            // the most direct absolute instant any copy carries
            let instant = input.claims
                .compactMap { c -> (Double, String)? in
                    guard let u = c.utcInstant, let s = c.utcSource, u > 631_152_000 else { return nil }
                    return (u, s)
                }
                .min { (utcRank[$0.1] ?? 9, $0.0) < (utcRank[$1.1] ?? 9, $1.0) }
            let named = input.claims.first { plausible($0.nameLocal) }

            if let best {
                r.localTime = best
                r.timeSource = "exif"
                stats.timeFromExif += 1
                if let o = bestOffset { r.utcOffset = o; r.zoneSource = "tag"; stats.zoneFromTag += 1 }
            } else if let n = named, let t = n.nameLocal {
                r.localTime = t
                r.timeSource = n.nameRule ?? "filename"
                stats.timeFromName += 1
            } else if let (u, src) = instant {
                r.instant = u
                r.timeSource = src
                stats.timeFromInstant += 1
                pendingUTC[out.count] = (u, src)
            } else if let m = input.claims.map(\.mtime).filter({ $0 > 0 }).min() {
                // last resort, and marked as such so the UI can say so
                r.localTime = wallClock(m, offset: 0)
                r.timeSource = "mtime (unreliable)"
                stats.timeFromMtime += 1
            }
            // A wall clock and an instant of the same moment give the zone exactly.
            // Not from a date-only filename: midnight is not when it was taken.
            if r.utcOffset == nil, let t = r.localTime, let (u, src) = instant,
               !r.timeSource.hasPrefix("mtime"), !r.timeSource.contains("date only"),
               let off = derivedOffset(local: t, instant: u) {
                r.utcOffset = offsetString(off)
                r.zoneSource = "clock + \(src) instant"
                stats.zoneDerived += 1
            }
            // a measured fix on any member is the strongest place evidence
            for c in input.claims where c.lat != nil {
                r.lat = c.lat; r.lon = c.lon
                r.placeSource = "measured"
                break
            }
            if r.lat == nil, let c = input.claims.first(where: { $0.sidecarLat != nil }) {
                r.lat = c.sidecarLat; r.lon = c.sidecarLon
                r.placeSource = "sidecar GPS"
            }
            if r.lat != nil { stats.placeMeasured += 1 }
            out.append(r)
        }

        // ---- 1-entered. a day you typed replaces only a missing date, a file-date
        // guess or a date-only name — never a date the file records.
        if !manual.isEmpty {
            for i in out.indices {
                guard let d = manual[out[i].clusterID]?.day else { continue }
                let ts = out[i].timeSource
                guard ts == "none" || ts.hasPrefix("mtime") || ts.contains("date only") else { continue }
                out[i].localTime = d + " " + Manual.dayTime
                out[i].timeSource = "you entered the day"
                out[i].instant = nil
                pendingUTC[i] = nil
                stats.timeEntered += 1
            }
        }

        // ---- 1a. an instant with no wall clock needs a zone before it has a day.
        // Only read-quality evidence is used, and a zone is never invented: with
        // none, the time is shown in UTC and said to be.
        if !pendingUTC.isEmpty {
            struct Obs { let lat: Double; let lon: Double; let month: Int; let offset: Double }
            var obs: [Obs] = []
            var known: [(t: Double, off: Double)] = []
            for r in out where readZone(r.zoneSource) {
                guard let o = r.utcOffset, let p = parse(r.localTime) else { continue }
                let off = offsetSeconds(o)
                if let la = r.lat, let lo = r.lon, readPlace(r.placeSource) {
                    obs.append(Obs(lat: la, lon: lo, month: p.mo, offset: off))
                }
                if let t = epoch(r.localTime, o) { known.append((t, off)) }
            }
            known.sort { $0.t < $1.t }
            for (i, pend) in pendingUTC {
                let month = parse(wallClock(pend.u, offset: 0))?.mo ?? 0
                var off: Double? = nil
                if let la = out[i].lat, let lo = out[i].lon {
                    var best: (d: Double, off: Double)? = nil
                    for o in obs {
                        let d = haversineKM(la, lo, o.lat, o.lon) + (o.month == month ? 0 : 50)
                        if best == nil || d < best!.d { best = (d, o.offset) }
                    }
                    if let b = best, b.d < 300 {
                        off = b.off; out[i].zoneSource = "from a nearby photo's own offset"
                    }
                }
                if off == nil, !known.isEmpty {
                    // nearest instant, by binary search
                    var lo = 0, hi = known.count - 1
                    while lo < hi { let m = (lo + hi) / 2; if known[m].t < pend.u { lo = m + 1 } else { hi = m } }
                    let cands = [lo - 1, lo].filter { $0 >= 0 && $0 < known.count }
                    if let k = cands.min(by: { abs(known[$0].t - pend.u) < abs(known[$1].t - pend.u) }),
                       abs(known[k].t - pend.u) <= 48 * 3600 {
                        off = known[k].off; out[i].zoneSource = "nearest photo in time"
                    }
                }
                if let off {
                    out[i].utcOffset = offsetString(off)
                    out[i].localTime = wallClock(pend.u, offset: off)
                } else {
                    out[i].localTime = wallClock(pend.u, offset: 0)
                    out[i].timeSource = pend.src + ", shown in UTC"
                    utcOnly.insert(i)
                }
            }
        }

        // ---- 1c. what you corrected: same instant, the right offset
        if !fixes.isEmpty {
            for i in out.indices {
                guard let o = fixes[out[i].clusterID] else { continue }
                let instant = out[i].instant ?? epoch(out[i].localTime, out[i].utcOffset)
                if let instant {
                    out[i].localTime = wallClock(instant, offset: offsetSeconds(o))
                    out[i].instant = instant
                    utcOnly.remove(i)
                    if out[i].timeSource.hasSuffix(", shown in UTC") {
                        out[i].timeSource = String(out[i].timeSource.dropLast(", shown in UTC".count))
                    }
                }
                out[i].utcOffset = o
                out[i].zoneSource = "you corrected it"
                stats.zoneCorrected += 1
            }
        }

        // ---- 1b. what you chose, before anything is inferred
        if !picks.isEmpty {
            // A pick fills a gap; it never overrides an offset the file itself
            // carries. Ballots are only ever offered for gaps, so this is belt and
            // braces against a stale pick after the collection changes.
            for i in out.indices where out[i].zoneSource == "none" && !utcOnly.contains(i) {
                guard let d = dayNumber(out[i].localTime), let o = picks[d] else { continue }
                out[i].utcOffset = o
                out[i].zoneSource = "you chose it"
                stats.zoneFromYou += 1
            }
        }

        // ---- 2. place: same day, same place; then nearest in time, travel-bounded
        var fixesByDay: [Int: [(sod: Int, lat: Double, lon: Double)]] = [:]
        for (idx, r) in out.enumerated() where readPlace(r.placeSource) && !utcOnly.contains(idx) {
            guard let d = dayNumber(r.localTime), let s = secondsOfDay(r.localTime),
                  let la = r.lat, let lo = r.lon else { continue }
            fixesByDay[d, default: []].append((s, la, lo))
        }
        // a day whose fixes cluster tightly was spent in one place
        var dayCentre: [Int: (Double, Double)] = [:]
        for (day, fixes) in fixesByDay where fixes.count > 0 {
            let la = fixes.map(\.lat).reduce(0, +) / Double(fixes.count)
            let lo = fixes.map(\.lon).reduce(0, +) / Double(fixes.count)
            let spread = fixes.map { haversineKM($0.lat, $0.lon, la, lo) }.max() ?? 0
            if spread <= params.dayRadiusKM { dayCentre[day] = (la, lo) }
        }
        for i in out.indices where out[i].placeSource == "none" && !utcOnly.contains(i) {
            guard let day = dayNumber(out[i].localTime) else { continue }
            if let c = dayCentre[day] {
                out[i].lat = c.0; out[i].lon = c.1
                out[i].placeSource = "same day, same place"
                stats.placeFromDay += 1
            } else if let fixes = fixesByDay[day], let sod = secondsOfDay(out[i].localTime) {
                // travel bound: how far could the photographer have got?
                let near = fixes.min { abs($0.sod - sod) < abs($1.sod - sod) }
                if let n = near {
                    let minutes = Double(abs(n.sod - sod)) / 60
                    if minutes <= params.travelMinutes {
                        out[i].lat = n.lat; out[i].lon = n.lon
                        out[i].placeSource = "nearest fix, \(Int(minutes)) min"
                        stats.placeFromNeighbour += 1
                    } else { stats.declinedDaySpansTooFar += 1 }
                }
            } else if fixesByDay[day] != nil {
                stats.declinedDaySpansTooFar += 1
            }
        }

        // ---- 2b. same folder, same place (BUILDLOG §2.18). A folder is usually a
        // trip, not a place — one named for a country held three weeks and 2,000 km — so it
        // names a place only when the photographs in it that DO carry a fix are
        // all close together. The same radius as "same day": no new threshold.
        var albumOf: [Int: String] = [:]
        for (i, input) in inputs.enumerated() {
            if let a = input.claims.compactMap(\.album).first { albumOf[i] = a }
        }
        if !albumOf.isEmpty {
            var fixes: [String: [(Double, Double)]] = [:]
            for (i, a) in albumOf where readPlace(out[i].placeSource) {
                if let la = out[i].lat, let lo = out[i].lon { fixes[a, default: []].append((la, lo)) }
            }
            var centre: [String: (Double, Double)] = [:]
            for (a, fx) in fixes where fx.count >= 3 {
                let la = fx.map(\.0).reduce(0, +) / Double(fx.count)
                let lo = fx.map(\.1).reduce(0, +) / Double(fx.count)
                let spread = fx.map { haversineKM($0.0, $0.1, la, lo) }.max() ?? 0
                if spread <= params.dayRadiusKM { centre[a] = (la, lo) } else { stats.declinedFolderSpansTooFar += 1 }
            }
            for (i, a) in albumOf where out[i].placeSource == "none" && !utcOnly.contains(i) {
                guard let c = centre[a] else { continue }
                out[i].lat = c.0; out[i].lon = c.1
                out[i].placeSource = "same folder, same place"
                stats.placeFromFolder += 1
            }
        }

        // ---- 2c. your place rules, last of all: a folder rule before a date rule,
        // the narrower range first, so the most specific thing you said wins.
        if !rules.isEmpty {
            let ordered = rules.sorted {
                ($0.folder == nil ? 1 : 0, ($0.dayTo ?? Int.max) - ($0.dayFrom ?? 0))
                    < ($1.folder == nil ? 1 : 0, ($1.dayTo ?? Int.max) - ($1.dayFrom ?? 0))
            }
            for i in out.indices where out[i].placeSource == "none" && !utcOnly.contains(i) {
                let day = dayNumber(out[i].localTime)
                guard let rule = ordered.first(where: { $0.matches(folder: albumOf[i], day: day) }) else { continue }
                out[i].lat = rule.lat; out[i].lon = rule.lon
                out[i].placeSource = "your rule: " + rule.label
                stats.placeFromRule += 1
            }
        }

        // ---- 2d. a place you typed replaces a missing or worked-out one — never a
        // place the file or its sidecar records.
        if !manual.isEmpty {
            for i in out.indices where !readPlace(out[i].placeSource) {
                guard let e = manual[out[i].clusterID], let la = e.lat, let lo = e.lon else { continue }
                out[i].lat = la; out[i].lon = lo
                out[i].placeSource = e.confirmed ? "you confirmed it" : "you entered it"
                stats.placeEntered += 1
            }
        }

        // ---- 3. zone from place — MEASURED fixes only (INHERITED §2.16).
        // No offline coordinate→timezone API exists on macOS and a shapefile is a
        // 50 MB dependency, so learn the mapping from this collection: every photo
        // that carries BOTH a measured fix and its own offset is an observation.
        struct Obs { let lat: Double; let lon: Double; let month: Int; let offset: Double }
        var observations: [Obs] = []
        for r in out where readPlace(r.placeSource) && readZone(r.zoneSource) {
            guard let la = r.lat, let lo = r.lon, let p = parse(r.localTime),
                  let o = r.utcOffset else { continue }
            observations.append(Obs(lat: la, lon: lo, month: p.mo, offset: offsetSeconds(o)))
        }
        for i in out.indices where out[i].zoneSource == "none" && !utcOnly.contains(i) {
            // a place you entered may look up its zone, though it never teaches one
            guard readPlace(out[i].placeSource) || out[i].placeSource == "you entered it" || out[i].placeSource == "you confirmed it",
                  let la = out[i].lat, let lo = out[i].lon,
                  let p = parse(out[i].localTime) else { continue }
            // nearest observation, preferring the same month so DST matches
            var best: (d: Double, off: Double)? = nil
            for ob in observations {
                let d = haversineKM(la, lo, ob.lat, ob.lon)
                    + (ob.month == p.mo ? 0 : 50)     // mild penalty for a different season
                if best == nil || d < best!.d { best = (d, ob.offset) }
            }
            if let b = best, b.d < 300 {              // within ~300 km of a known offset
                out[i].utcOffset = offsetString(b.off)
                out[i].zoneSource = "from a nearby photo's own offset"
                stats.zoneFromPlace += 1
            }
        }

        // ---- 4. zone from the nearest dated neighbour, for what is still unknown
        let known = out.enumerated()
            .filter { $0.element.zoneSource != "none" && $0.element.localTime != nil }
            .compactMap { (idx: $0.offset, day: dayNumber($0.element.localTime), off: $0.element.utcOffset) }
            .compactMap { t -> (Int, Int, String)? in
                guard let d = t.day, let o = t.off else { return nil }
                return (t.idx, d, o)
            }
            .sorted { $0.1 < $1.1 }
        if !known.isEmpty {
            for i in out.indices where out[i].zoneSource == "none" && !utcOnly.contains(i) {
                guard let d = dayNumber(out[i].localTime) else { continue }
                var best: (gap: Int, off: String)? = nil
                for k in known {
                    let gap = abs(k.1 - d)
                    if best == nil || gap < best!.gap { best = (gap, k.2) }
                    if gap == 0 { break }
                }
                if let b = best, b.gap <= 2 {         // within two days
                    out[i].utcOffset = b.off
                    out[i].zoneSource = "nearest dated photo"
                    stats.zoneFromNeighbour += 1
                }
            }
        }

        // ---- 5. re-anchor: a wall clock is only an instant once its zone is known
        for i in out.indices {
            // an instant read as an instant stands; otherwise one exists only with a zone
            if out[i].instant == nil { out[i].instant = epoch(out[i].localTime, out[i].utcOffset) }
            if out[i].localTime != nil { stats.dated += 1 }
            if out[i].utcOffset != nil { stats.zoned += 1 }
            if out[i].lat != nil { stats.located += 1 }
        }
        return (out, stats)
    }

    /// Everything a ballot needs, grouped by day and computed once. Built so the
    /// same code path can be used to *back-test* the ballot: hide a day whose zone
    /// is known, re-derive it, and see whether the ballot agrees (PLAN §11, M6).
    struct DayIndex {
        var offsetByDay: [Int: Double] = [:]
        var offsetByModelDay: [String: [Int: Double]] = [:]
        var lonByDay: [Int: (lon: Double, measured: Bool)] = [:]
        var photosByDay: [Int: [Ballot.Photo]] = [:]
        var modelByDay: [Int: String] = [:]
        var unzonedDays: Set<Int> = []
        /// Days whose date was read off the photograph, not off the filesystem.
        var realDays: Set<Int> = []
    }

    static func index(_ inputs: [Input], _ resolved: [Resolved]) -> DayIndex {
        var byID: [Int: Input] = [:]
        for i in inputs { byID[i.clusterID] = i }

        var ix = DayIndex()
        // Sorted, because several of these maps keep one value per day and the
        // caller's array order is a dictionary's iteration order.
        for r in resolved.sorted(by: { $0.clusterID < $1.clusterID }) {
            guard let day = dayNumber(r.localTime) else { continue }
            if r.timeSource == "exif" { ix.realDays.insert(day) }
            if let o = r.utcOffset { ix.offsetByDay[day] = offsetSeconds(o) }
            else if r.timeSource == "exif" { ix.unzonedDays.insert(day) }
            if let lo = r.lon { ix.lonByDay[day] = (lo, r.placeSource == "measured") }

            let c = byID[r.clusterID]?.claims.first
            if let model = c?.model {
                ix.modelByDay[day] = model
                if let o = r.utcOffset { ix.offsetByModelDay[model, default: [:]][day] = offsetSeconds(o) }
            }
            if let sod = secondsOfDay(r.localTime) {
                ix.photosByDay[day, default: []].append(Ballot.Photo(
                    secondsOfDay: sod, ev: c?.ev,
                    epochMillisName: c?.fileName.flatMap(Ballot.epochMillisFromName)))
            }
        }
        return ix
    }

    /// The context for one day. `hiding` removes days from the evidence — pass the
    /// day itself to ask what the ballot would say if its zone were unknown.
    static func context(_ day: Int, _ ix: DayIndex, hiding: Set<Int> = []) -> Ballot.Context? {
        guard let photos = ix.photosByDay[day], !photos.isEmpty else { return nil }

        // Nearest day with a zone. Equidistant days are common — one either side —
        // so the tie is broken by majority offset and then by the earlier day, or
        // the same collection would score differently on every run.
        var nearest: (off: Double, gap: Int)? = nil
        var minGap = Int.max
        for (d, _) in ix.offsetByDay where !hiding.contains(d) { minGap = min(minGap, abs(d - day)) }
        if minGap != Int.max {
            var tally: [Double: Int] = [:]
            for (d, o) in ix.offsetByDay where !hiding.contains(d) && abs(d - day) == minGap {
                tally[o, default: 0] += 1
            }
            if let best = tally.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }) {
                nearest = (best.key, minGap)
            }
        }
        var deviceOffset: Double? = nil, deviceSamples = 0
        if let model = ix.modelByDay[day], let hist = ix.offsetByModelDay[model] {
            var tally: [Double: Int] = [:]
            for (d, o) in hist where abs(d - day) <= 14 && !hiding.contains(d) { tally[o, default: 0] += 1 }
            if let best = tally.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }) {
                deviceOffset = best.key; deviceSamples = best.value
            }
        }
        let lon = ix.lonByDay[day]
        return Ballot.Context(
            day: day, photos: photos,
            longitude: lon?.lon, longitudeIsMeasured: lon?.measured ?? false,
            neighbourOffset: nearest?.off, neighbourGapDays: nearest?.gap ?? 999,
            deviceOffset: deviceOffset, deviceSamples: deviceSamples)
    }

    /// Ballots for whatever is still unzoned, grouped by day (PLAN §7.4).
    /// Proposals only — nothing here is applied.
    ///
    /// Only days whose *date* came off the photograph are offered: a day assembled
    /// from filesystem timestamps is not a day the person was anywhere, so asking
    /// them to zone it is a nonsense question.
    static func ballots(_ inputs: [Input], _ resolved: [Resolved]) -> [DayBallot] {
        let ix = index(inputs, resolved)
        var counts: [Int: Int] = [:]
        for r in resolved {
            guard r.utcOffset == nil, r.timeSource == "exif",
                  let d = dayNumber(r.localTime) else { continue }
            counts[d, default: 0] += 1
        }
        var out: [DayBallot] = []
        for day in ix.unzonedDays {
            guard let ctx = context(day, ix) else { continue }
            let b = Ballot.rank(ctx)
            guard !b.ranked.isEmpty else { continue }
            out.append(DayBallot(day: day, dateLabel: dayLabel(day),
                                 photographs: counts[day] ?? 0, ballot: b))
        }
        return out.sorted { $0.photographs > $1.photographs }
    }
}
