import Foundation

// Headless test harness. Exercises the engine's pure parts against real files and
// against hand-built cases from INHERITED.md. No UI, no actors.

var failures = 0
var checks = 0

func check(_ name: String, _ cond: Bool, _ detail: String = "") {
    checks += 1
    if cond { print("  ok    \(name)") }
    else { failures += 1; print("  FAIL  \(name)  \(detail)") }
}

func eq<T: Equatable>(_ name: String, _ got: T, _ want: T) {
    check(name, got == want, "got \(got), want \(want)")
}

// ---------------------------------------------------------------- BK-tree

func testBKTree() {
    print("\nBK-tree")
    let t = BKTree()
    t.add(0b0000, 1)
    t.add(0b0001, 2)          // distance 1 from the first
    t.add(0b1111, 3)          // distance 4
    t.add(0b0000, 4)          // duplicate key, must not collapse the node
    eq("stores duplicate keys", t.count, 4)
    eq("radius 0 finds both at distance 0", Set(t.query(0b0000, radius: 0)), Set([1, 4]))
    eq("radius 1 reaches distance 1", Set(t.query(0b0000, radius: 1)), Set([1, 2, 4]))
    eq("radius 4 reaches everything", Set(t.query(0b0000, radius: 4)), Set([1, 2, 3, 4]))
    eq("hamming is symmetric", BKTree.distance(0b1010, 0b0101), 4)
}

// ---------------------------------------------------------------- cascade

/// A synthetic 64x64 thumb filled with one value. MAE between two of them is
/// exactly the difference of those values, at every resolution — i.e. zero slope.
func flat(_ v: UInt8) -> [UInt8] { Array(repeating: v, count: 64 * 64) }

/// 64x64 with fine detail that survives at full size but averages away when shrunk
/// to 16x16 — the signature of two genuinely different photographs.
func detailed(_ seed: Int) -> [UInt8] {
    var out = [UInt8](repeating: 128, count: 64 * 64)
    var x = UInt64(seed &* 2654435761 &+ 1)
    for i in 0..<out.count {
        x ^= x << 13; x ^= x >> 7; x ^= x << 17          // xorshift, deterministic
        // high-frequency swing around a constant mean, so the 16x16 average matches
        out[i] = UInt8(truncatingIfNeeded: 128 &+ (Int(x % 121) - 60))
    }
    return out
}

func item(_ id: Int, sha: String? = nil, pixel: String? = nil, dhash: UInt64? = nil,
          bytes: Int = 1000, w: Int = 100, h: Int = 100, thumb: [UInt8]? = flat(128),
          capturedAt: String? = nil) -> Clusterer.Item {
    .init(id: id, sha: sha, pixel: pixel, dhash: dhash, bytes: bytes,
          width: w, height: h, thumb: thumb, capturedAt: capturedAt)
}

func testCascade() {
    print("\nidentity cascade")

    // Tier A
    var r = Clusterer.cluster([item(1, sha: "a"), item(2, sha: "a"), item(3, sha: "b")], radius: 0)
    eq("tier A groups byte-identical", r.groups.count, 2)
    eq("tier A counted", r.tierA, 1)

    // Tier B: same pixels, different bytes — the case that makes re-export cheap
    r = Clusterer.cluster([item(1, sha: "a", pixel: "p"), item(2, sha: "b", pixel: "p")], radius: 0)
    eq("tier B groups identical pixels", r.groups.count, 1)
    eq("tier B labels the method", r.groups[0].method, "same image")

    // Tier C respects the radius dial, and only merges what verification confirms
    let near = [item(1, sha: "a", dhash: 0b0000), item(2, sha: "b", dhash: 0b0011)]
    eq("radius 0 keeps distance-2 apart", Clusterer.cluster(near, radius: 0).groups.count, 2)
    eq("radius 2 joins them when pixels agree", Clusterer.cluster(near, radius: 2).groups.count, 1)

    // THE regression that matters: a dHash neighbour whose pixels disagree must not
    // be merged. Without this, radius 4 merged 117 unrelated photographs spanning
    // 2016-2026 on a real library.
    let collide = [item(1, sha: "a", dhash: 0b0000, thumb: detailed(1)),
                   item(2, sha: "b", dhash: 0b0011, thumb: detailed(2))]
    var v = Clusterer.cluster(collide, radius: 4)
    eq("different photographs are not merged", v.groups.count, 2)
    eq("rejected by the slope test", v.rejected > 0, true)

    // The three verdicts, which one resolution cannot distinguish. Measured on a
    // real library: all eleven candidates scored under 8 at 16x16, yet nine were
    // different photographs, one was an edit, and only one was a true duplicate.
    eq("flat and identical  -> confirm", Clusterer.verify(flat(100), flat(100)), Clusterer.Verdict.confirm)
    eq("flat and mid        -> review",  Clusterer.verify(flat(100), flat(112)), Clusterer.Verdict.review)
    eq("rising with detail  -> reject",  Clusterer.verify(detailed(3), detailed(4)), Clusterer.Verdict.reject)

    // A tone grade must never be merged away silently — it is a different picture
    // to look at, however identical its structure (INHERITED §2.22).
    let graded = [item(1, sha: "a", dhash: 0b0000, thumb: flat(100)),
                  item(2, sha: "b", dhash: 0b0000, thumb: flat(112))]
    v = Clusterer.cluster(graded, radius: 4)
    eq("a colour grade stays separate", v.groups.count, 2)
    eq("and is flagged for review", v.needsReview > 0, true)

    // shrink must average, not sample
    eq("shrink halves the grid", Clusterer.shrink(flat(200), from: 64, to: 16).count, 256)
    eq("shrink preserves a flat value", Clusterer.shrink(flat(200), from: 64, to: 16)[0], 200)

    // Transitive chaining must not sneak past the gate
    let chain = [item(1, sha: "a", dhash: 0b0000_0000, thumb: flat(10)),
                 item(2, sha: "b", dhash: 0b0000_1111, thumb: flat(120)),
                 item(3, sha: "c", dhash: 0b1111_1111, thumb: flat(240))]
    v = Clusterer.cluster(chain, radius: 4)
    eq("no transitive chain through unverified pairs", v.groups.count, 3)
    eq("longest chain stays 1", v.longestChain, 1)

    // A candidate with no thumb cannot be confirmed
    let blind = [item(1, sha: "a", dhash: 0b0000, thumb: nil),
                 item(2, sha: "b", dhash: 0b0001, thumb: nil)]
    eq("unverifiable candidates are not merged", Clusterer.cluster(blind, radius: 2).groups.count, 2)

    // Separation guard: a burst must survive as separate photographs even when
    // the frames look near-identical at 16x16. Nine frames of one scene, minutes
    // apart, were wrongly merged on a real library before this existed.
    let burst = (0..<5).map { n in
        item(n + 1, sha: "s\(n)", dhash: 0b0000, thumb: flat(100),
             capturedAt: "2025:07:04 22:23:4\(n)")
    }
    var bv = Clusterer.cluster(burst, radius: 4)
    eq("burst frames stay separate", bv.groups.count, 5)
    eq("separations are counted", bv.separated > 0, true)

    // ...but genuine copies, which share a capture instant, still merge
    let copies = [item(1, sha: "a", dhash: 0b0000, thumb: flat(100), capturedAt: "2025:07:04 22:23:40"),
                  item(2, sha: "b", dhash: 0b0001, thumb: flat(100), capturedAt: "2025:07:04 22:23:40")]
    bv = Clusterer.cluster(copies, radius: 4)
    eq("copies sharing an instant still merge", bv.groups.count, 1)

    // a missing capture time must not block a merge
    let oneUndated = [item(1, sha: "a", dhash: 0b0000, thumb: flat(100), capturedAt: "2025:07:04 22:23:40"),
                      item(2, sha: "b", dhash: 0b0001, thumb: flat(100), capturedAt: nil)]
    eq("missing date falls through to pixels", Clusterer.cluster(oneUndated, radius: 4).groups.count, 1)

    // MAE itself
    eq("mae of identical thumbs", Clusterer.mae(flat(100), flat(100)), 0.0)
    eq("mae of 100 vs 108", Clusterer.mae(flat(100), flat(108)), 8.0)
    eq("mae rejects mismatched sizes", Clusterer.mae([1,2], [1,2,3]), 255.0)

    // Best copy: more pixels wins over larger file
    r = Clusterer.cluster([item(1, sha: "a", pixel: "p", bytes: 9_000, w: 100, h: 100),
                           item(2, sha: "b", pixel: "p", bytes: 1_000, w: 400, h: 400)], radius: 0)
    eq("keeps the larger resolution", r.groups[0].members[r.groups[0].canonical == 0 ? 0 : 0], 1)
    check("canonical is the 400x400 copy", r.groups[0].canonical == 1)
    eq("wasted counts only the losers", r.groups[0].wasted, 9_000)

    // Determinism: identical on every criterion must still order stably
    let tie = [item(7, sha: "x", pixel: "p"), item(3, sha: "y", pixel: "p")]
    let a = Clusterer.cluster(tie, radius: 0).groups[0].members
    let b = Clusterer.cluster(tie.reversed(), radius: 0).groups[0].members
    eq("tie-break is deterministic", a.map { tie[$0].id }.first, b.map { tie.reversed()[$0].id }.first)

    // Empty input must not crash
    eq("empty input", Clusterer.cluster([], radius: 4).groups.count, 0)
}

// ---------------------------------------------------------------- video, tier D

func vid(_ id: Int, _ dur: Double, _ frames: [UInt64], bytes: Int = 1000,
         pixels: Int = 1920*1080, thumb: [UInt8]? = flat(120),
         at: String? = nil) -> Clusterer.Video {
    .init(id: id, duration: dur, frames: frames, bytes: bytes, pixels: pixels,
          thumb: thumb, capturedAt: at)
}

func testVideo() {
    print("\nvideo, tier D")

    let f: [UInt64] = [0x0f0f_0f0f, 0x3333_3333, 0xaaaa_aaaa]
    eq("same duration + frames is one recording",
       Clusterer.sameRecording(vid(1, 12.00, f), vid(2, 12.05, f)), true)
    eq("duration beyond tolerance is not",
       Clusterer.sameRecording(vid(1, 12.0, f), vid(2, 13.0, f)), false)
    eq("same duration, different frames is not",
       Clusterer.sameRecording(vid(1, 12.0, f), vid(2, 12.0, [1, 2, 3])), false)
    eq("no frames means no claim",
       Clusterer.sameRecording(vid(1, 12.0, []), vid(2, 12.0, [])), false)

    // a re-encode: duration rounds slightly differently, frames shift a bit
    let shifted = f.map { $0 ^ 0b11 }        // 2 bits per frame, inside the tolerance
    eq("a re-encode still matches", Clusterer.sameRecording(vid(1, 12.0, f), vid(2, 12.1, shifted)), true)

    var r = Clusterer.clusterVideos([vid(1, 12.0, f, bytes: 9000), vid(2, 12.05, f, bytes: 4000)])
    eq("re-encodes group", r.groups.count, 1)
    eq("tier D counted", r.tierD, 1)
    eq("largest kept", vid(1, 12.0, f).id, 1)
    eq("wasted is the loser only", r.groups[0].wasted, 4000)

    // the separation guard applies to video too
    r = Clusterer.clusterVideos([vid(1, 12.0, f, at: "2022:01:01 10:00:00"),
                                 vid(2, 12.0, f, at: "2022:01:01 10:00:05")])
    eq("clips recorded at different instants stay apart", r.groups.count, 2)
    eq("separation counted", r.separated > 0, true)

    // two unrelated clips of the same length must not merge
    r = Clusterer.clusterVideos([vid(1, 30.0, f), vid(2, 30.0, [0xffff, 0x0000, 0xf0f0])])
    eq("same length, different content stays apart", r.groups.count, 2)

    eq("ISO-6709 parsed", VideoExtractor.parseISO6709("+37.7858-122.4064+010.000/")?.0 ?? 0, 37.7858)
    eq("null island rejected", VideoExtractor.parseISO6709("+00.0000+000.0000/") == nil, true)
    eq("frame pack round trip", VideoExtractor.unpack(VideoExtractor.pack(f)), f)
}

// ---------------------------------------------------------------- resolver

func claim(_ t: String?, off: String? = nil, lat: Double? = nil, lon: Double? = nil,
           mtime: Double = 0) -> Resolver.Claim {
    .init(capturedAt: t, utcOffset: off, lat: lat, lon: lon, mtime: mtime)
}
func input(_ id: Int, _ cs: Resolver.Claim...) -> Resolver.Input {
    .init(clusterID: id, claims: cs)
}

func testResolver() {
    print("\nresolver")

    // parsing and civil-date arithmetic
    eq("parses a capture time", Resolver.parse("2021:03:07 14:22:31")?.mo, 3)
    eq("rejects rubbish", Resolver.parse("not a date") == nil, true)
    eq("day number is monotonic",
       Resolver.dayNumber("2021:03:08 00:00:00")! - Resolver.dayNumber("2021:03:07 00:00:00")!, 1)
    eq("epoch 1970", Resolver.epoch("1970:01:01 00:00:00", "+00:00"), 0.0)
    eq("offset parsing +08:00", Resolver.offsetSeconds("+08:00"), 28800.0)
    eq("offset parsing -05:30", Resolver.offsetSeconds("-05:30"), -19800.0)
    eq("offset round trip", Resolver.offsetString(28800), "+08:00")
    eq("offset round trip negative", Resolver.offsetString(-19800), "-05:30")

    // INHERITED §2.6 — a capture time can only be wrong LATE, so earliest wins
    var (r, _) = Resolver.resolve([input(1,
        claim("2021:03:07 14:22:31"), claim("2023:09:01 10:00:00"))])
    eq("earliest plausible claim wins", r[0].localTime, "2021:03:07 14:22:31")

    // implausible dates are rejected, not merely ranked low
    (r, _) = Resolver.resolve([input(1, claim("1975:01:01 00:00:00"), claim("2021:03:07 14:22:31"))])
    eq("pre-1990 claim rejected", r[0].localTime, "2021:03:07 14:22:31")

    // mtime is a last resort and says so
    (r, _) = Resolver.resolve([input(1, claim(nil, mtime: 1_600_000_000))])
    eq("falls back to mtime", r[0].timeSource, "mtime (unreliable)")

    // INHERITED §2.5 — a timestamp shared by very many files is an export artifact
    let batch = (1...30).map { input($0, claim("2018:12:30 07:05:00")) }
    let (br, bs) = Resolver.resolve(batch)
    eq("batch timestamps downgraded", bs.batchDowngraded > 0, true)
    eq("and so nothing is dated by them", br.allSatisfy { $0.timeSource != "exif" }, true)

    // place: same day, same place
    let day = [input(1, claim("2022:08:16 09:00:00", off: "-06:00", lat: 44.47, lon: -110.72)),
               input(2, claim("2022:08:16 10:00:00", off: "-06:00", lat: 44.48, lon: -110.73)),
               input(3, claim("2022:08:16 11:00:00", off: "-06:00"))]
    var (dr, ds) = Resolver.resolve(day)
    eq("unlocated photo inherits the day's place", dr[2].placeSource, "same day, same place")
    eq("and the centre is near the fixes", abs(dr[2].lat! - 44.475) < 0.02, true)
    eq("measured fixes counted", ds.placeMeasured, 2)

    // ...but a day that spans too far must DECLINE, not average
    let travel = [input(1, claim("2022:08:16 09:00:00", off: "-06:00", lat: 44.47, lon: -110.72)),
                  input(2, claim("2022:08:16 21:00:00", off: "-06:00", lat: 40.76, lon: -111.89)),
                  input(3, claim("2022:08:16 15:00:00", off: "-06:00"))]
    (dr, ds) = Resolver.resolve(travel)
    eq("a travel day is declined, not averaged", dr[2].placeSource == "same day, same place", false)
    eq("decline is counted", ds.declinedDaySpansTooFar > 0, true)

    // zone: only a MEASURED fix may certify one (INHERITED §2.16)
    let zoned = [input(1, claim("2017:07:11 12:00:00", off: "+08:00", lat: 1.29, lon: 103.85)),
                 input(2, claim("2017:07:11 13:00:00", lat: 1.30, lon: 103.86))]
    let (zr, zs) = Resolver.resolve(zoned)
    eq("zone learned from a nearby photo's own tag", zr[1].utcOffset, "+08:00")
    eq("and attributed honestly", zr[1].zoneSource, "from a nearby photo's own offset")
    eq("counted", zs.zoneFromPlace, 1)

    // a wall clock only becomes an instant once its zone is known
    (r, _) = Resolver.resolve([input(1, claim("2021:03:07 14:22:31"))])
    eq("no zone means no instant", r[0].instant == nil, true)
    (r, _) = Resolver.resolve([input(1, claim("2021:03:07 14:22:31", off: "+08:00"))])
    eq("with a zone, an instant exists", r[0].instant != nil, true)

    eq("day label round trip", Resolver.dayLabel(Resolver.dayNumber("2021:03:07 00:00:00")!), "7 Mar 2021")
    eq("day label handles January", Resolver.dayLabel(Resolver.dayNumber("2020:01:01 00:00:00")!), "1 Jan 2020")

    // haversine sanity
    check("haversine: Singapore to Kuala Lumpur ~316 km",
          abs(Resolver.haversineKM(1.29, 103.85, 3.139, 101.687) - 316) < 10)
}

// ---------------------------------------------------------------- ballot

func testBallot() {
    print("\nthe timezone ballot")

    eq("epoch-ms filename recognised",
       Ballot.epochMillisFromName("mmexport1500000000000.jpg"), 1500000000000.0)
    eq("a short number is not an epoch",
       Ballot.epochMillisFromName("IMG_2207.JPG") == nil, true)
    eq("candidates include the half-hour zones",
       Ballot.candidates.contains(5.5 * 3600), true)
    eq("candidates exclude invented ones",
       Ballot.candidates.contains(1.25 * 3600), false)

    // no signals at all ⇒ no ballot. Silence, not a guess.
    var ctx = Ballot.Context(day: 18000, photos: [])
    eq("nothing to go on means no candidates", Ballot.rank(ctx).ranked.isEmpty, true)

    // a neighbouring day is strong evidence when it is close
    ctx = Ballot.Context(day: 18000,
                         photos: (0..<5).map { .init(secondsOfDay: 36000 + $0 * 600, ev: nil, epochMillisName: nil) },
                         neighbourOffset: 8 * 3600, neighbourGapDays: 1)
    var r = Ballot.rank(ctx)
    eq("the neighbour's zone leads", r.ranked.first?.offsetString, "+08:00")

    // the daylight curve alone, with a longitude and no other evidence.
    // At 116.4°E solar noon is at UTC 12 − 116.4/15 = 04:13.
    // Photographed light peaking at 12:15 local therefore implies about +08:00.
    let peak = 12.25
    let evs: [Ballot.Photo] = (0..<9).map { i in
        let h = peak - 4 + Double(i)                       // 08:15 … 16:15
        let ev = 14 - abs(h - peak) * 1.5                  // brightest at the peak
        return .init(secondsOfDay: Int(h * 3600), ev: ev, epochMillisName: nil)
    }
    ctx = Ballot.Context(day: 18000, photos: evs, longitude: 116.4)
    r = Ballot.rank(ctx)
    // Daylight is a veto, not a pointer: back-testing 1,354 days showed that as a
    // ranking signal it was worse than nothing, because the centre of a day's
    // photography sits well after solar noon. It must still rule out the far side
    // of the world, and it must refuse to name an hour.
    check("daylight keeps the right offset in contention",
          r.ranked.contains { abs($0.offset - 8 * 3600) <= 3600 })
    check("daylight rules out the far side of the world",
          Ballot.rank(ctx).ranked.allSatisfy { abs($0.offset - 8 * 3600) < 10 * 3600 })
    check("daylight alone cannot name the hour", r.indistinguishable)
    check("and it says how it got there",
          r.signals.contains { $0.hasPrefix("Daylight") })

    // a filename with an absolute instant beats everything
    // 1500000000000 ms is 02:40:00 UTC, so a +08:00 clock reads 10:40:00.
    let ms = 1_500_000_000_000.0
    ctx = Ballot.Context(day: 17361,
                         photos: [.init(secondsOfDay: 10 * 3600 + 40 * 60,
                                        ev: nil, epochMillisName: ms)],
                         neighbourOffset: -5 * 3600, neighbourGapDays: 1)
    r = Ballot.rank(ctx)
    eq("an absolute filename pins the offset", r.ranked.first?.offsetString, "+08:00")
    // ...and when a neighbouring day flatly contradicts it, that is a conflict the
    // user should see, not something to resolve silently.
    check("a contradicted filename is flagged as indistinguishable", r.indistinguishable)

    // REFUSAL: two candidates that cannot be separated must not be offered
    ctx = Ballot.Context(day: 18000,
                         photos: (0..<5).map { .init(secondsOfDay: 36000 + $0 * 600, ev: nil, epochMillisName: nil) },
                         neighbourOffset: 8 * 3600, neighbourGapDays: 14)
    r = Ballot.rank(ctx)
    check("a fortnight-old neighbour is weak evidence", r.margin < 0.2)

    // the floor: a best score below it is not offered at all
    let saved = Ballot.confidenceFloor
    Ballot.confidenceFloor = 0.99
    eq("below the confidence floor, the ballot refuses", Ballot.rank(ctx).usable, false)
    Ballot.confidenceFloor = saved

    // ---- the ballot inside the resolver, end to end
    // Two days from one camera: the first tagged, the second bare. The second
    // should surface as a ballot, and picking should settle it.
    func day(_ n: Int, _ time: String, _ offset: String?, _ lat: Double? = nil,
             _ lon: Double? = nil) -> Resolver.Input {
        Resolver.Input(clusterID: n, claims: [Resolver.Claim(
            capturedAt: time, utcOffset: offset, lat: lat, lon: lon, mtime: 0,
            model: "X100V")])
    }
    // Eight days apart: past the resolver's two-day neighbour rule, but inside the
    // fortnight a ballot signal will look across. Only a ballot is left.
    var inputs = (0..<4).map { i in day(i, "2021:03:0\(i + 1) 12:00:00", "+08:00", 31.2, 121.5) }
    inputs += (0..<4).map { i in day(10 + i, "2021:03:1\(i + 2) 1\(i):00:00", nil) }
    var (res, st) = Resolver.resolve(inputs)
    let bs = Resolver.ballots(inputs, res)
    check("an unzoned day becomes a ballot", !bs.isEmpty)
    eq("only the unzoned days are balloted",
       bs.allSatisfy { b in res.contains { Resolver.dayNumber($0.localTime) == b.day && $0.utcOffset == nil } },
       true)
    check("the ballot explains itself", bs.first?.ballot.signals.isEmpty == false)
    check("the ballot is dated in words", bs.first?.dateLabel.contains("Mar") == true)
    check("the ballot names its evidence",
          bs.first?.ballot.signals.contains { $0.hasPrefix("Neighbouring day") } == true)
    // A neighbour and a camera habit agree on the hour but cannot rule out the hour
    // either side, so the ballot says so rather than picking (INHERITED §2.20).
    check("one hour either side cannot be separated", bs.first?.ballot.indistinguishable == true)
    // Every offered offset sits within an hour of the neighbour's. Note that
    // +08:45 (Eucla) outranks +09:00 — the real candidate list is not the integers.
    check("every offered offset is within an hour of the evidence",
          bs.first?.ballot.ranked.allSatisfy { abs($0.offset - 8 * 3600) <= 3600 } == true)
    eq("the best offered offset is the neighbour's",
       bs.first?.ballot.ranked.first?.offsetString, "+08:00")

    // picking one settles that day, and nothing else
    if let target = bs.first {
        (res, st) = Resolver.resolve(inputs, picks: [target.day: "+09:00"])
        let onThatDay = res.filter { Resolver.dayNumber($0.localTime) == target.day }
        check("the chosen day is zoned", onThatDay.allSatisfy { $0.utcOffset == "+09:00" })
        eq("and says who chose it", onThatDay.first?.zoneSource, "you chose it")
        check("the choice is counted", st.zoneFromYou == onThatDay.count)
        check("a chosen day becomes an instant", onThatDay.first?.instant != nil)
        // and it no longer appears on the ballot
        check("a settled day leaves the ballot",
              !Resolver.ballots(inputs, res).contains { $0.day == target.day })
    }

    // a day dated only from the filesystem is not balloted: the date is not a date
    let mtimeOnly = [Resolver.Input(clusterID: 99, claims: [Resolver.Claim(
        capturedAt: nil, utcOffset: nil, lat: nil, lon: nil, mtime: 1_600_000_000)])]
    let (mr, _) = Resolver.resolve(inputs + mtimeOnly)
    let mtimeDay = mr.first { $0.clusterID == 99 }.flatMap { Resolver.dayNumber($0.localTime) }
    check("a filesystem-dated day is not put to a vote",
          !Resolver.ballots(inputs + mtimeOnly, mr).contains { $0.day == mtimeDay })

    // a pick must never overrule what the file itself recorded
    let tagged = [day(0, "2021:03:01 12:00:00", "+08:00", 31.2, 121.5)]
    let d0 = Resolver.dayNumber("2021:03:01 12:00:00")!
    let (kept, _) = Resolver.resolve(tagged, picks: [d0: "-05:00"])
    eq("a pick does not overrule the file's own offset", kept.first?.utcOffset, "+08:00")
}

// ---------------------------------------------------------------- sniff

func testSniff(_ root: URL) {
    print("\nmagic-byte typing (INHERITED §2.2)")
    let fm = FileManager.default
    var seen: [String: Int] = [:]
    var mismatch: [(String, String, String)] = []
    var n = 0
    if let e = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
        for case let u as URL in e {
            guard let r = Sniff.sniff(u) else { continue }
            seen[r.mime, default: 0] += 1
            // does the extension agree with the bytes?
            let ext = u.pathExtension.lowercased()
            let expected: String? = ["jpg": "image/jpeg", "jpeg": "image/jpeg",
                                     "png": "image/png", "heic": "image/heic",
                                     "mov": "video/mp4", "mp4": "video/mp4"][ext]
            if let expected, expected != r.mime { mismatch.append((u.lastPathComponent, ext, r.mime)) }
            n += 1
            if n >= 3000 { break }
        }
    }
    check("typed \(n) real files", n > 0)
    for (m, c) in seen.sorted(by: { $0.value > $1.value }) { print("        \(c)\t\(m)") }
    check("extension disagreements: \(mismatch.count)", true)
    for m in mismatch.prefix(5) { print("        \(m.0): .\(m.1) but bytes say \(m.2)") }
}

// ---------------------------------------------------------------- extract

func testExtract(_ root: URL) {
    print("\nextraction on real files")
    let fm = FileManager.default
    var urls: [URL] = []
    if let e = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
        for case let u as URL in e {
            if let r = Sniff.sniff(u), r.kind == .image { urls.append(u) }
            if urls.count >= 200 { break }
        }
    }
    guard !urls.isEmpty else { check("found images", false); return }

    var withDate = 0, withGPS = 0, withHash = 0
    var hashes: [String: Int] = [:]
    for u in urls {
        guard let f = Extractor.extract(u, isImage: true) else { continue }
        if f.capturedAt != nil { withDate += 1 }
        if f.lat != nil { withGPS += 1 }
        if let p = f.pixelHash { withHash += 1; hashes[p, default: 0] += 1 }
    }
    check("extracted \(urls.count) images", withHash == urls.count,
          "only \(withHash) produced a pixel hash")
    print("        dated: \(withDate)/\(urls.count)   located: \(withGPS)/\(urls.count)")
    let collisions = hashes.values.filter { $0 > 1 }.count
    print("        pixel-hash groups with >1 member: \(collisions)")

    // determinism: the same file must hash the same twice
    if let u = urls.first,
       let a = Extractor.extract(u, isImage: true),
       let b = Extractor.extract(u, isImage: true) {
        eq("pixel hash is deterministic", a.pixelHash, b.pixelHash)
        eq("dhash is deterministic", a.dhash64, b.dhash64)
        eq("sha256 is deterministic", a.sha256, b.sha256)
    }
}

// ---------------------------------------------------------------- catalog

// ---------------------------------------------------------------- pipeline

/// The stages the *app* runs, against a real SQLite catalog. This exists because the
/// app once ran its own unverified copy of tier C while every other test here ran
/// `Clusterer` — so the cascade was green and the product merged unrelated photos.
func testPipeline() {
    print("\nthe pipeline the app runs")
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pm-pipe-\(UUID().uuidString)/catalog.sqlite")
    guard let c = try? Catalog(url: tmp) else { check("opens", false); return }
    defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }

    // four images, one dHash, one instant: only the pixels can tell them apart
    //   1, 2  the same photograph, re-encoded (2 is smaller)
    //   3     a different photograph that happens to share a dHash
    //   4     a burst frame: same pixels as 1, but a second later
    let same = detailed(7)
    var reencoded = same; for i in stride(from: 0, to: reencoded.count, by: 97) { reencoded[i] &+= 1 }
    let rows: [(Int, [UInt8], String, Int)] = [
        (1, same,        "2021:05:01 10:00:00", 5000),
        (2, reencoded,   "2021:05:01 10:00:00", 3000),
        (3, detailed(8), "2021:05:01 10:00:00", 4000),
        (4, same,        "2021:05:01 10:00:01", 4500),
    ]
    try? c.transaction {
        let s0 = try c.prepare("INSERT INTO source(id, path, added_at) VALUES(1,'/x',0);")
        s0.done(); s0.finalize()
        let st = try c.prepare("""
            INSERT INTO file(id, source_id, path, rel_path, size, mtime, kind, sha256,
                             dhash64, width, height, thumb, captured_at, utc_offset, state)
            VALUES(?,1,?,?,?,0,'image',?,?,100,100,?,?,'+08:00','extracted');
            """)
        for (id, thumb, t, size) in rows {
            st.bind(1, id).bind(2, "/x/\(id).jpg").bind(3, "\(id).jpg").bind(4, size)
              .bind(5, "sha\(id)").bind(6, UInt64(0xABCD)).bind(7, Data(thumb)).bind(8, t)
            st.done(); st.reset()
        }
        st.finalize()
    }
    guard let rep = try? Pipeline.cluster(c, radius: 4) else { check("clusters", false); return }
    eq("re-encoded copies merge; the rest stand alone", rep.assets, 3)
    eq("exactly one duplicate", rep.duplicates, 1)
    eq("the duplicate is the smaller re-encode",
       c.scalarInt("SELECT file_id FROM member WHERE role='duplicate';"), 2)
    eq("a different photograph with the same dHash is not merged",
       c.scalarInt("SELECT COUNT(*) FROM member m1 JOIN member m2 ON m1.cluster_id=m2.cluster_id WHERE m1.file_id=1 AND m2.file_id=3;"), 0)
    eq("a burst frame a second later is not merged",
       c.scalarInt("SELECT COUNT(*) FROM member m1 JOIN member m2 ON m1.cluster_id=m2.cluster_id WHERE m1.file_id=1 AND m2.file_id=4;"), 0)

    // every candidate is recorded, once, with what became of it
    func outcome(_ a: Int, _ b: Int) -> String? {
        guard let st = try? c.prepare("SELECT outcome FROM pair WHERE a=? AND b=?;") else { return nil }
        defer { st.finalize() }
        st.bind(1, a).bind(2, b)
        return st.step() ? st.text(0) : nil
    }
    eq("the re-encode is recorded as merged", outcome(1, 2), "merged")
    eq("the look-alike is recorded as rejected", outcome(1, 3), "rejected")
    eq("the burst frame is recorded as a burst", outcome(1, 4), "burst")
    eq("each pair once", c.scalarInt("SELECT COUNT(*) FROM pair;"), 6)

    // the radius preview, over the same items the real run groups
    let pv = Preview.radii(Pipeline.imageItems(c), [0, 4])
    eq("radius 0 merges nothing by perceptual distance", pv.rows[0].merged, 0)
    eq("radius 4 merges the re-encode", pv.rows[1].merged, 1)
    eq("and shows it as a sample", pv.samples[4]?.map { [$0.a, $0.b] }, [[1, 2]])
    eq("the preview matches the real run", pv.rows[1].duplicates, rep.duplicates)
    eq("previewing wrote nothing", c.scalarInt("SELECT COUNT(*) FROM pair WHERE outcome='merged';"), 1)

    // re-running replaces rather than accumulates
    _ = try? Pipeline.cluster(c, radius: 4)
    eq("re-running the stage is idempotent", c.scalarInt("SELECT COUNT(*) FROM cluster;"), 3)

    // choosing the other copy
    Pipeline.keep(c, 2, siblings: [1, 2])
    _ = try? Pipeline.cluster(c, radius: 4)
    eq("the chosen copy is kept", c.scalarInt("SELECT file_id FROM member WHERE role='canonical' AND file_id IN (1,2);"), 2)
    eq("the larger one becomes the duplicate", c.scalarInt("SELECT file_id FROM member WHERE role='duplicate';"), 1)
    eq("what is recoverable follows the choice",
       c.scalarInt("SELECT wasted FROM cluster JOIN member ON member.cluster_id=cluster.id WHERE file_id=2;"), 5000)
    eq("and the reason says who chose",
       c.scalarInt("SELECT COUNT(*) FROM member WHERE file_id=2 AND reason='kept: you chose this copy';"), 1)
    Pipeline.keep(c, 1, siblings: [1, 2])
    eq("one keeper per group", c.scalarInt("SELECT COUNT(*) FROM keeper;"), 1)
    Pipeline.keep(c, nil, siblings: [1, 2])
    _ = try? Pipeline.cluster(c, radius: 4)
    eq("clearing the choice restores the ranking",
       c.scalarInt("SELECT file_id FROM member WHERE role='canonical' AND file_id IN (1,2);"), 1)

    // stored dials round-trip, and the resolve that the app runs uses them
    eq("no stored dials means defaults", Pipeline.params(c), Resolver.Params())
    var tuned = Resolver.Params(); tuned.travelMinutes = 15; tuned.dayRadiusKM = 5
    Pipeline.setParams(c, tuned)
    eq("stored dials read back", Pipeline.params(c), tuned)
    Pipeline.setRadius(c, 6)
    eq("stored radius reads back", Pipeline.radius(c), 6)
    Pipeline.setParams(c, .init()); Pipeline.setRadius(c, 4)

    // resolve writes one row per asset and honours a choice
    guard let res = try? Pipeline.resolve(c) else { check("resolves", false); return }
    eq("one resolution per asset", res.resolved.count, 3)
    eq("offsets read off the files", c.scalarInt("SELECT COUNT(*) FROM resolution WHERE zone_source='tag';"), 3)

    // ---- decisions, read back from the same catalog
    let cid = c.scalarInt("SELECT cluster_id FROM member WHERE file_id = 1;")
    guard let asset = Decisions.load(c, cluster: cid) else { check("decision loads", false); return }
    eq("the asset carries both copies", asset.files.count, 2)
    eq("the kept copy comes first", asset.canonical?.id, 1)
    let steps = Decisions.explain(asset)
    eq("four questions answered", steps.map(\.topic), ["Identity", "When", "Timezone", "Where"])
    check("identity names the pixel check", steps[0].why.contains("pixel comparison"))
    check("identity names the kept file", steps[0].why.contains("1.jpg"))
    eq("a date off the file is read, not inferred", steps[1].provenance, .read)
    eq("an offset off the file is read", steps[2].provenance, .read)
    eq("no GPS anywhere is unknown, and says so", steps[3].provenance, .unknown)
    check("an unknown place explains itself", steps[3].why.contains("No copy has GPS"))

    eq("the default list hides what was simply read", Decisions.list(c, .inferred).total, 0)
    eq("everything lists every asset", Decisions.list(c, .all).total, 3)
    eq("duplicates lists the merged one", Decisions.list(c, .duplicates).rows.map(\.id), [cid])
    eq("all three lack a place", Decisions.list(c, .noPlace).total, 3)

    // ---- boundary cases: a person's verdict
    // a tone-graded copy: every pixel lifted evenly — flat slope, not identical
    try? c.transaction {
        let st = try c.prepare("""
            INSERT INTO file(id, source_id, path, rel_path, size, mtime, kind, sha256,
                             dhash64, width, height, thumb, captured_at, utc_offset, state)
            VALUES(5,1,'/x/5.jpg','5.jpg',4800,0,'image','sha5',?,100,100,?,
                   '2021:05:01 10:00:00','+08:00','extracted');
            """)
        st.bind(1, UInt64(0xABCD)).bind(2, Data(same.map { $0 &+ 10 })).done(); st.finalize()
    }
    _ = try? Pipeline.cluster(c, radius: 4)
    eq("a tone grade is put to a person, not merged", outcome(1, 5), "variant")
    eq("so it stands alone", c.scalarInt("SELECT size FROM cluster JOIN member ON member.cluster_id=cluster.id WHERE file_id=5;"), 1)

    Pipeline.decide(c, 1, 5, same: true)
    _ = try? Pipeline.cluster(c, radius: 4)
    eq("'same' joins it", outcome(1, 5), "youSame")
    eq("and the group says who decided",
       c.scalarInt("SELECT COUNT(*) FROM cluster JOIN member ON member.cluster_id=cluster.id WHERE file_id=5 AND method='chosen';"), 1)

    Pipeline.decide(c, 1, 2, same: false)
    _ = try? Pipeline.cluster(c, radius: 4)
    eq("'different' overrides a pixel match", outcome(1, 2), "youDifferent")

    // ids change on rescan; content does not
    try? c.transaction {
        // as a real rescan does: groups are rebuilt, files come back under new ids
        try c.run("DELETE FROM member; DELETE FROM cluster; UPDATE file SET id = id + 100, path = path || '.moved';")
    }
    _ = try? Pipeline.cluster(c, radius: 4)
    eq("a verdict survives a rescan that renumbers every file", outcome(101, 105), "youSame")

    Pipeline.decide(c, 101, 105, same: nil)
    Pipeline.decide(c, 101, 102, same: nil)
    _ = try? Pipeline.cluster(c, radius: 4)
    eq("withdrawing a verdict restores the machine's judgement", outcome(101, 105), "variant")
    eq("both ways", outcome(101, 102), "merged")
    try? c.transaction {
        try c.run("""
            DELETE FROM member; DELETE FROM cluster; DELETE FROM file WHERE id = 105;
            UPDATE file SET id = id - 100, path = replace(path, '.moved', '');
            """)
    }
    _ = try? Pipeline.cluster(c, radius: 4)
    _ = try? Pipeline.resolve(c)

    let recs = Export.records(c)
    eq("one export record per asset", recs.count, 3)
    let merged = recs.first { $0.asset == cid }
    eq("the kept copy is the canonical one", merged?.kept, "/x/1.jpg")
    eq("its duplicate is listed", merged?.duplicates, ["/x/2.jpg"])
    eq("a zoned time exports its UTC instant", merged?.instantUTC, "2021-05-01T02:00:00Z")
}

func testPreviewOrder() {
    func pr(_ a: Int, _ o: Clusterer.Pair.Outcome, _ m: Double) -> Clusterer.Pair {
        .init(a: a, b: a + 100, distance: 1, outcome: o, maeHi: m, maeLo: m)
    }
    let order = Preview.weakestFirst([pr(1, .variant, 20), pr(2, .merged, 1), pr(3, .variant, 6),
                                      pr(4, .merged, 3.9)]).map(\.a)
    eq("merges first, nearest the threshold first; then questions, most alike first", order, [4, 2, 3, 1])
}

func testPreview() {
    print("\npreviewing the place dials")
    // one day: two fixes in Paris at 10:00 and 10:30, one bare photo at 12:00
    // (90 minutes on) — and a far-apart fix that stops "same day, same place"
    let ins = [
        input(1, claim("2022:06:01 10:00:00", off: "+02:00", lat: 48.85, lon: 2.35)),
        input(2, claim("2022:06:01 10:30:00", off: "+02:00", lat: 48.86, lon: 2.34)),
        input(3, claim("2022:06:01 12:00:00", off: "+02:00")),
        input(4, claim("2022:06:01 18:00:00", off: "+02:00", lat: 45.76, lon: 4.83)),   // Lyon
    ]
    let now = Resolver.resolve(ins).out
    eq("at 60 minutes the bare photo has no place", now.first { $0.clusterID == 3 }?.lat == nil, true)
    var wide = Resolver.Params(); wide.travelMinutes = 120
    let pr = Preview.places(ins, picks: [:], current: now, candidate: wide)
    eq("at 120 minutes it gains one", pr.changes.map(\.clusterID), [3])
    eq("and says it was gained", pr.changes.first?.kind, .gained)
    eq("from the nearest fix", pr.changes.first?.after.hasPrefix("nearest fix"), true)
    eq("the count moves by exactly one", pr.located, now.filter { $0.lat != nil }.count + 1)
    let same = Preview.places(ins, picks: [:], current: now, candidate: .init())
    check("previewing the current setting changes nothing", same.changes.isEmpty)
}

import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// A small, distinct JPEG — real bytes for the real extractor.
func writeJPEG(_ url: URL, seed: Int, side: Int = 96, exifDate: String? = nil) {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                              bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    var x = UInt64(seed &* 2654435761 &+ 7)
    func r() -> CGFloat { x ^= x << 13; x ^= x >> 7; x ^= x << 17; return CGFloat(x % 1000) / 1000 }
    for _ in 0..<12 {
        ctx.setFillColor(red: r(), green: r(), blue: r(), alpha: 1)
        ctx.fill(CGRect(x: r() * CGFloat(side), y: r() * CGFloat(side),
                        width: r() * CGFloat(side), height: r() * CGFloat(side)))
    }
    guard let img = ctx.makeImage(),
          let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    else { return }
    var props: [CFString: Any] = [:]
    if let exifDate {
        props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: exifDate]
    }
    CGImageDestinationAddImage(d, img, props as CFDictionary)
    CGImageDestinationFinalize(d)
}

func testIngest() {
    print("\nscan and extract: resumable")
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pm-ingest-\(UUID().uuidString)")
    let photos = dir.appendingPathComponent("photos")
    try? FileManager.default.createDirectory(at: photos.appendingPathComponent("sub"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    for i in 0..<40 {
        writeJPEG(photos.appendingPathComponent(i % 4 == 0 ? "sub/p\(i).jpg" : "p\(i).jpg"), seed: i)
    }
    try? Data("not a photo".utf8).write(to: photos.appendingPathComponent("notes.jpg"))  // lies about itself
    guard let c = try? Catalog(url: dir.appendingPathComponent("c.sqlite")) else { check("opens", false); return }
    try? c.transaction {
        let st = try c.prepare("INSERT INTO source(path, added_at) VALUES(?,0);")
        st.bind(1, photos.path).done(); st.finalize()
    }

    var sr = Ingest.scan(c)
    eq("every real photo is found", sr.added, 40)
    eq("a file named .jpg that is not one is skipped", c.scalarInt("SELECT COUNT(*) FROM file WHERE path LIKE '%notes.jpg';"), 0)
    sr = Ingest.scan(c)
    eq("a second scan adds nothing", sr.added, 0)
    eq("and changes nothing", sr.changed, 0)

    // interrupted: stop once the first batch is in
    let stop = Ingest.Stop()
    let first = Ingest.extract(c, workers: 2, batch: 5, stop: stop) { done, _ in if done >= 10 { stop.set() } }
    let afterStop = c.scalarInt("SELECT COUNT(*) FROM file WHERE state='extracted';")
    check("a stopped run says so", first.stopped)
    check("what was read before the stop is kept", afterStop >= 10 && afterStop < 40)
    let rest = Ingest.extract(c, workers: 2, batch: 5)
    eq("the next run reads only what is left", rest.total, 40 - afterStop)
    eq("and then everything is read", c.scalarInt("SELECT COUNT(*) FROM file WHERE state='extracted';"), 40)
    eq("nothing is read twice or lost", c.scalarInt("SELECT COUNT(DISTINCT sha256) FROM file;"), 40)
    eq("a run with nothing left does nothing", Ingest.extract(c, workers: 2).total, 0)

    // a file that cannot be read is failed, not retried forever
    let broken = photos.appendingPathComponent("broken.jpg")
    var bytes = (try? Data(contentsOf: photos.appendingPathComponent("p1.jpg"))) ?? Data()
    bytes = bytes.prefix(16)                                  // a real JPEG header, then nothing
    try? bytes.write(to: broken)
    _ = Ingest.scan(c)
    _ = Ingest.extract(c, workers: 1)
    // an undecodable image keeps its content hash, so identical damaged copies
    // still group — it just has no pixels to compare
    eq("a damaged image is kept by hash, without pixels",
       c.scalarInt("SELECT COUNT(*) FROM file WHERE path LIKE '%broken.jpg' AND state='extracted' AND sha256 IS NOT NULL AND width=0;"), 1)
    // a file that cannot be opened at all is failed, and not retried forever
    let locked = photos.appendingPathComponent("locked.jpg")
    writeJPEG(locked, seed: 77)
    _ = Ingest.scan(c)
    chmod(locked.path, 0)
    let br = Ingest.extract(c, workers: 1)
    chmod(locked.path, 0o644)
    eq("a file that cannot be opened is marked failed", br.failed, 1)
    eq("and not attempted again", Ingest.extract(c, workers: 1).total, 0)
    try? FileManager.default.removeItem(at: locked)
    try? FileManager.default.removeItem(at: broken)
    _ = Ingest.scan(c)

    // a file that changes is read again; a file that goes away is forgotten
    Thread.sleep(forTimeInterval: 1.1)
    writeJPEG(photos.appendingPathComponent("p2.jpg"), seed: 999)
    try? FileManager.default.removeItem(at: photos.appendingPathComponent("p3.jpg"))
    sr = Ingest.scan(c)
    eq("a changed file is noticed", sr.changed, 1)
    eq("a deleted file is forgotten", sr.removed, 1)
    eq("and the changed one is read again", Ingest.extract(c, workers: 1).done, 1)

    // an unplugged drive is not an empty folder
    let parked = dir.appendingPathComponent("parked")
    try? FileManager.default.moveItem(at: photos, to: parked)
    let before = c.scalarInt("SELECT COUNT(*) FROM file;")
    sr = Ingest.scan(c)
    eq("a missing source is reported", sr.unavailable, [photos.path])
    eq("and none of its files are forgotten", c.scalarInt("SELECT COUNT(*) FROM file;"), before)

    // an interrupted walk must not conclude anything is gone
    try? FileManager.default.moveItem(at: parked, to: photos)
    sr = Ingest.scan(c, limit: 5)
    eq("a partial walk removes nothing", sr.removed, 0)
    _ = Ingest.scan(c)
    // exclusions: a folder by name, files by pattern — and already-read files are forgotten
    try? FileManager.default.createDirectory(at: photos.appendingPathComponent("Screenshots"), withIntermediateDirectories: true)
    writeJPEG(photos.appendingPathComponent("Screenshots/s1.jpg"), seed: 501)
    writeJPEG(photos.appendingPathComponent("keep.JPG"), seed: 502)
    _ = Ingest.scan(c)
    let expected = c.scalarInt("SELECT COUNT(*) FROM file WHERE path NOT LIKE '%/Screenshots/%' AND rel_path NOT LIKE 'sub/%';")
    let inSub = c.scalarInt("SELECT COUNT(*) FROM file WHERE rel_path LIKE 'sub/%';")
    try? c.transaction { try c.run("UPDATE source SET exclude = 'screenshots\nsub/*\n# a comment';") }
    sr = Ingest.scan(c)
    eq("a pattern's files are counted as excluded", sr.excluded, inSub)   // a named folder is skipped whole
    eq("and what was read from them is forgotten", c.scalarInt("SELECT COUNT(*) FROM file;"), expected)
    check("there was something to exclude", inSub > 0 && expected > 1)
    check("the rest stays", c.scalarInt("SELECT COUNT(*) FROM file WHERE path LIKE '%keep.JPG';") == 1)
    try? c.transaction { try c.run("UPDATE source SET exclude = '*.jpg';") }
    sr = Ingest.scan(c)
    check("a glob matches whatever the case", c.scalarInt("SELECT COUNT(*) FROM file;") == 0)
    try? c.transaction { try c.run("UPDATE source SET exclude = NULL;") }
    _ = Ingest.scan(c)

}

func testNamesAndSidecars() {
    print("\nfilenames and sidecars")
    let pxlUTC = Resolver.epoch("2025:07:20 16:12:54", "+00:00")!
    eq("a Pixel name is a UTC instant", Names.claim("PXL_20250720_161254963.jpg"),
       .utc(pxlUTC, rule: "Pixel filename (UTC)"))
    eq("an IMG_ name is a wall clock", Names.claim("IMG_20240101_120000.jpg"),
       .wall("2024:01:01 12:00:00", rule: "filename"))
    eq("so is a VID_ name with milliseconds", Names.claim("VID_20241212_105113123.mp4"),
       .wall("2024:12:12 10:51:13", rule: "filename"))
    eq("a macOS screenshot", Names.claim("Screenshot 2024-03-05 at 09.08.07.png"),
       .wall("2024:03:05 09:08:07", rule: "filename"))
    eq("an Android screenshot", Names.claim("Screenshot_2019-01-02-03-04-05.png"),
       .wall("2019:01:02 03:04:05", rule: "filename"))
    eq("WhatsApp gives a date only", Names.claim("IMG-20240101-WA0001.jpg"),
       .wall("2024:01:01 00:00:00", rule: "WhatsApp filename (date only)"))
    eq("an epoch-ms name is UTC", Names.claim("mmexport1500000000000.jpg"),
       .utc(1500000000.0, rule: "epoch filename (UTC)"))
    eq("an ordinary number is not a date", Names.claim("IMG_2207.JPG"), nil)
    eq("an impossible date is not a date", Names.claim("IMG_20241399_250000.jpg"), nil)
    eq("a Takeout year folder", Names.folder("Photos from 2019/IMG_1.jpg").year, 2019)
    eq("an album folder", Names.folder("Takeout/Google Photos/Iceland 2019/IMG_1.jpg").album, "Iceland 2019")
    for storage in ["F/IMG.jpg", "originals/0/IMG.jpg", "DCIM/100APPLE/IMG.jpg", "2019-07/IMG.jpg",
                    "Photos Library.photoslibrary/originals/A/x.heic", "C3A1-44F2/IMG.jpg"] {
        eq("storage is not a place: \(storage)", Names.folder(storage).album, nil)
    }
    eq("a place name survives", Names.folder("DCIM/Botanic Garden/IMG.jpg").album, "Botanic Garden")
    eq("so does a non-Latin one", Names.folder("東京/IMG.jpg").album, "東京")

    // the cascade, against both collision conventions and mismatched case
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pm-sc-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    for n in ["IMG_0088 (1).jpeg.supplemental-metadata.json", "IMG_0899.HEIC.supplemental-metadata(1).json",
              "IMG_0460.mov.supplemental-metadata.json", "PXL_1.jpg.supplemental-metadata.json",
              "PXL_2.MP.jpg.json", "SCAN.json"] {
        try? Data("{}".utf8).write(to: dir.appendingPathComponent(n))
    }
    let ix = Sidecar.Index()
    func rule(_ media: String) -> String? { Sidecar.find(dir.appendingPathComponent(media).path, ix)?.rule }
    eq("collision number on the media", rule("IMG_0088 (1).jpeg"), "exact")
    eq("collision number on the sidecar", rule("IMG_0899(1).HEIC"), "collision")
    eq("extension case need not agree", rule("IMG_0460.MOV"), "exact")
    eq("an edit inherits from its origin", rule("PXL_1-edited.jpg"), "edit of origin")
    eq("a motion photo still", rule("PXL_2.MP.jpg"), "bare")
    eq("an extensionless match by stem", rule("SCAN.tif"), "stem")
    eq("no sidecar is no sidecar", rule("UNRELATED.jpg"), nil)

    let json = #"{"title":"IMG_1.jpg","photoTakenTime":{"timestamp":"1563120000"},"geoData":{"latitude":0.0,"longitude":0.0},"geoDataExif":{"latitude":44.46,"longitude":-110.83}}"#
    let f = Sidecar.parse(Data(json.utf8))
    eq("the taken time is an instant", f?.takenUTC, 1563120000)
    eq("the camera's own fix is used", f?.lat, 44.46)
    let null = Sidecar.parse(Data(#"{"geoData":{"latitude":0.0,"longitude":0.0}}"#.utf8))
    eq("(0, 0) means no location", null?.lat, nil)

    // every real sidecar in the workspace export, if present
    // A real Takeout export, if you have one: PM_TAKEOUT=/path/to/Takeout ./test.sh
    let takeout = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PM_TAKEOUT"] ?? "/nonexistent")
    if let e = FileManager.default.enumerator(atPath: takeout.path) {
        var total = 0, parsed = 0, timed = 0
        while let rel = e.nextObject() as? String {
            guard rel.hasSuffix(".json") else { continue }
            total += 1
            if let d = FileManager.default.contents(atPath: takeout.appendingPathComponent(rel).path),
               let sf = Sidecar.parse(d) { parsed += 1; if sf.takenUTC != nil { timed += 1 } }
        }
        if total > 0 {
            print("    real sidecars: \(parsed)/\(total) parsed, \(timed) with a capture instant")
            check("every real sidecar parses", parsed == total)
        }
    }
}

func testInstants() {
    print("\nabsolute instants, and zones derived from them")
    func c(_ t: String? = nil, off: String? = nil, lat: Double? = nil, lon: Double? = nil,
           u: Double? = nil, src: String? = nil, name: String? = nil, rule: String? = nil,
           slat: Double? = nil, slon: Double? = nil, mtime: Double = 0) -> Resolver.Claim {
        var x = Resolver.Claim(capturedAt: t, utcOffset: off, lat: lat, lon: lon, mtime: mtime)
        x.utcInstant = u; x.utcSource = src; x.nameLocal = name; x.nameRule = rule
        x.sidecarLat = slat; x.sidecarLon = slon
        return x
    }
    let noonAtPlus8UTC = Resolver.epoch("2019:07:14 04:00:00", "+00:00")!   // 12:00 at +08:00

    // a wall clock and an instant of the same moment are its timezone
    var (r, st) = Resolver.resolve([input(1, c("2019:07:14 12:00:00", u: noonAtPlus8UTC, src: "Takeout sidecar"))])
    eq("a clock plus an instant gives the offset", r[0].utcOffset, "+08:00")
    eq("and says how", r[0].zoneSource, "clock + Takeout sidecar instant")
    eq("counted as derived", st.zoneDerived, 1)
    eq("the instant agrees", r[0].instant, noonAtPlus8UTC)

    // an instant alone, placed by a sidecar near a photo that records its offset
    (r, _) = Resolver.resolve([
        input(1, c("2019:07:14 09:00:00", off: "+08:00", lat: 1.29, lon: 103.85)),
        input(2, c(u: noonAtPlus8UTC, src: "Takeout sidecar", slat: 1.30, slon: 103.84)),
    ])
    let two = r.first { $0.clusterID == 2 }!
    eq("an instant takes the zone of where it was taken", two.utcOffset, "+08:00")
    eq("and becomes a local time", two.localTime, "2019:07:14 12:00:00")
    eq("its place is the sidecar's, as read", two.placeSource, "sidecar GPS")
    eq("its time says where it came from", two.timeSource, "Takeout sidecar")

    // an instant alone, no place: the nearest photo in time lends its zone
    (r, _) = Resolver.resolve([
        input(1, c("2019:07:14 09:00:00", off: "+08:00")),
        input(2, c(u: noonAtPlus8UTC, src: "video container")),
    ])
    eq("an instant three hours from a zoned photo borrows its zone",
       r.first { $0.clusterID == 2 }?.zoneSource, "nearest photo in time")

    // an instant with nothing near it is never given a zone
    (r, _) = Resolver.resolve([
        input(1, c("2019:07:09 09:00:00", off: "+08:00")),                 // five days earlier
        input(2, c(u: noonAtPlus8UTC, src: "Pixel filename (UTC)")),
    ])
    let lone = r.first { $0.clusterID == 2 }!
    eq("a lone instant gets no zone", lone.utcOffset, nil)
    eq("is shown in UTC, and says so", lone.timeSource, "Pixel filename (UTC), shown in UTC")
    eq("but keeps its instant", lone.instant, noonAtPlus8UTC)

    // filename clocks rank between EXIF and the file date
    (r, _) = Resolver.resolve([input(1, c(name: "2020:01:02 03:04:05", rule: "filename", mtime: 1_700_000_000))])
    eq("a filename's clock beats the file date", r[0].timeSource, "filename")
    (r, _) = Resolver.resolve([input(1, c("2021:05:05 05:05:05", name: "2020:01:02 03:04:05", rule: "filename"))])
    eq("EXIF beats a filename", r[0].localTime, "2021:05:05 05:05:05")
    (r, _) = Resolver.resolve([input(1, c(u: noonAtPlus8UTC, src: "Takeout sidecar",
                                          name: "2019:07:14 00:00:00", rule: "WhatsApp filename (date only)"))])
    eq("a date-only name derives no zone from midnight", r[0].utcOffset, nil)

    // a folder names a place only when its own fixes agree
    func inAlbum(_ id: Int, _ album: String, _ t: String, lat: Double? = nil, lon: Double? = nil) -> Resolver.Input {
        var x = c(t, off: "+08:00", lat: lat, lon: lon); x.album = album
        return input(id, x)
    }
    (r, st) = Resolver.resolve([
        inAlbum(1, "Botanic Garden", "2016:05:01 10:00:00", lat: 1.3138, lon: 103.8159),
        inAlbum(2, "Botanic Garden", "2016:05:02 10:00:00", lat: 1.3150, lon: 103.8150),
        inAlbum(3, "Botanic Garden", "2016:05:03 10:00:00", lat: 1.3130, lon: 103.8165),
        inAlbum(4, "Botanic Garden", "2016:05:09 10:00:00"),            // no fix, alone on its day
        inAlbum(5, "Italy", "2019:02:01 10:00:00", lat: 41.90, lon: 12.50),    // Rome
        inAlbum(6, "Italy", "2019:02:04 10:00:00", lat: 43.77, lon: 11.25),    // Florence
        inAlbum(7, "Italy", "2019:02:07 10:00:00", lat: 40.85, lon: 14.27),    // Naples
        inAlbum(8, "Italy", "2019:02:09 10:00:00"),
    ])
    eq("a folder whose fixes agree names a place", r.first { $0.clusterID == 4 }?.placeSource, "same folder, same place")
    eq("a folder that is a trip does not", r.first { $0.clusterID == 8 }?.lat, nil)
    eq("and the refusal is counted", st.declinedFolderSpansTooFar, 1)

    // your rules: last, most specific first, never over evidence
    var inF = c("2017:03:05 10:00:00", off: "+08:00"); inF.album = "Cottage"
    let bare = c("2017:06:01 10:00:00", off: "+08:00")
    let placedByFix = c("2017:06:02 10:00:00", off: "+08:00", lat: 1, lon: 1)
    let rules = [Resolver.PlaceRule(id: 1, folder: nil, dayFrom: Resolver.dayNumber("2017:01:01 00:00:00"),
                                    dayTo: Resolver.dayNumber("2017:12:31 00:00:00"), lat: 1.29, lon: 103.85, label: "2017, Singapore"),
                 Resolver.PlaceRule(id: 2, folder: "Cottage", dayFrom: nil, dayTo: nil, lat: 3.14, lon: 101.69, label: "the cottage")]
    (r, st) = Resolver.resolve([input(1, inF), input(2, bare), input(3, placedByFix)], rules: rules)
    eq("a folder rule beats a date rule", r.first { $0.clusterID == 1 }?.lat, 3.14)
    eq("a date rule places the rest of the year", r.first { $0.clusterID == 2 }?.placeSource, "your rule: 2017, Singapore")
    eq("a rule never overrides evidence", r.first { $0.clusterID == 3 }?.placeSource, "measured")
    eq("rules are counted", st.placeFromRule, 2)

    eq("an offset that is not a real zone is refused",
       Resolver.derivedOffset(local: "2019:07:14 12:07:00", instant: noonAtPlus8UTC), nil)
    eq("video local-with-offset parses",
       VideoExtractor.localWithOffset("2021-04-14T08:00:00+0800").map { [$0.0, $0.1] },
       ["2021:04:14 08:00:00", "+08:00"])
}

func testTakeoutEndToEnd() {
    print("\na Takeout-shaped folder, end to end")
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pm-to-\(UUID().uuidString)")
    let year = dir.appendingPathComponent("Takeout/Google Photos/Photos from 2019")
    try? FileManager.default.createDirectory(at: year, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    func sidecar(_ media: String, _ ts: Int, lat: Double? = nil, lon: Double? = nil, title: String? = nil) {
        var o: [String: Any] = ["photoTakenTime": ["timestamp": String(ts)]]
        if let lat, let lon { o["geoDataExif"] = ["latitude": lat, "longitude": lon] }
        if let title { o["title"] = title }
        let d = try! JSONSerialization.data(withJSONObject: o)
        try? d.write(to: year.appendingPathComponent(media + ".supplemental-metadata.json"))
    }
    let t = Int(Resolver.epoch("2019:07:14 04:00:00", "+00:00")!)    // 12:00 at +08:00
    // A: EXIF clock, sidecar instant + GPS  → zone derived exactly
    writeJPEG(year.appendingPathComponent("A.jpg"), seed: 1, exifDate: "2019:07:14 12:00:00")
    sidecar("A.jpg", t, lat: 1.29, lon: 103.85)
    // B: no EXIF date; sidecar instant + GPS nearby → zone of the place
    writeJPEG(year.appendingPathComponent("B.jpg"), seed: 2)
    sidecar("B.jpg", t + 600, lat: 1.30, lon: 103.84)
    // C: a Pixel name and nothing else → a UTC instant, zone from the nearest photo in time
    writeJPEG(year.appendingPathComponent("PXL_20190714_050000000.jpg"), seed: 3)
    // D: renamed on export; the original name survives only in the sidecar title
    writeJPEG(year.appendingPathComponent("image(1).jpg"), seed: 4)
    sidecar("image(1).jpg", 0, title: "IMG_20190714_130000.jpg")

    guard let c = try? Catalog(url: dir.appendingPathComponent("c.sqlite")) else { check("opens", false); return }
    try? c.transaction {
        let st = try c.prepare("INSERT INTO source(path, added_at) VALUES(?,0);")
        st.bind(1, dir.appendingPathComponent("Takeout").path).done(); st.finalize()
    }
    _ = Ingest.scan(c)
    eq("sidecars are not mistaken for photographs", c.scalarInt("SELECT COUNT(*) FROM file;"), 4)
    _ = Ingest.extract(c, workers: 2)
    eq("every sidecar is matched", c.scalarInt("SELECT COUNT(*) FROM file WHERE sidecar IS NOT NULL;"), 3)
    eq("the year folder is read", c.scalarInt("SELECT COUNT(*) FROM file WHERE folder_year = 2019;"), 4)
    _ = try? Pipeline.cluster(c, radius: 4)
    guard let res = try? Pipeline.resolve(c) else { check("resolves", false); return }
    func row(_ name: String) -> Resolver.Resolved? {
        let id = c.scalarInt("SELECT m.cluster_id FROM member m JOIN file f ON f.id=m.file_id WHERE f.path LIKE '%/\(name)';")
        return res.resolved.first { $0.clusterID == id }
    }
    eq("A: zone derived from its clock and its sidecar", row("A.jpg")?.zoneSource, "clock + Takeout sidecar instant")
    eq("A: +08:00", row("A.jpg")?.utcOffset, "+08:00")
    eq("B: dated by its sidecar", row("B.jpg")?.timeSource, "Takeout sidecar")
    eq("B: local time at +08:00", row("B.jpg")?.localTime, "2019:07:14 12:10:00")
    eq("B: placed by its sidecar", row("B.jpg")?.placeSource, "sidecar GPS")
    eq("C: a Pixel name read as UTC, zoned by its neighbour",
       row("PXL_20190714_050000000.jpg")?.localTime, "2019:07:14 13:00:00")
    eq("D: dated by the name it had before export", row("image(1).jpg")?.localTime, "2019:07:14 13:00:00")
    eq("nothing fell back to the file date", res.stats.timeFromMtime, 0)
}

func testCompanions() {
    print("\nLive Photos and motion photos")
    typealias S = Companions.Side
    func st(_ g: Int, _ ids: [String] = [], _ paths: [String]) -> S {
        S(group: g, contentIDs: Set(ids), stems: Set(paths.map(Companions.stem)))
    }
    func mv(_ g: Int, _ ids: [String] = [], _ paths: [String], _ d: Double) -> S {
        S(group: g, contentIDs: Set(ids), stems: Set(paths.map(Companions.stem)), duration: d)
    }
    eq("a Photos library's own naming shares a stem",
       Companions.stem("/L/0/ABC.heic"), Companions.stem("/L/0/ABC_3.mov"))
    eq("so does a Google motion pair", Companions.stem("/T/PXL_1.MP.jpg"), Companions.stem("/T/PXL_1.MP"))

    var p = Companions.pair(stills: [st(0, ["X"], ["/a/IMG_1.HEIC"])],
                            movies: [mv(0, ["X"], ["/b/totally_different.mov"], 2.5)])
    eq("the identifier decides, whatever the names", p[0]?.rule, "content identifier")

    // the §2.11 failure: a long unrelated video with the same name beside the real clip
    p = Companions.pair(stills: [st(0, [], ["/a/IMG_7.JPG"])],
                        movies: [mv(0, [], ["/a/IMG_7.MOV"], 36), mv(1, [], ["/a/IMG_7(1).MOV", "/a/IMG_7.mov"], 2.8)])
    eq("a name alone attaches only a short clip", p[0]?.movie, 1)
    p = Companions.pair(stills: [st(0, [], ["/a/IMG_8.JPG"])], movies: [mv(0, [], ["/a/IMG_8.MOV"], 36)])
    eq("a long video that shares a name is not a companion", p[0] == nil, true)

    p = Companions.pair(stills: [st(0, [], ["/a/IMG_9.JPG"])], movies: [mv(0, ["OTHER"], ["/a/IMG_9.MOV"], 2)])
    eq("a movie whose identifier names another still is not paired by name", p[0] == nil, true)

    p = Companions.pair(stills: [st(0, ["Y"], ["/a/P.HEIC"])],
                        movies: [mv(0, ["Y"], ["/a/P.MOV"], 2), mv(1, ["Y"], ["/b/P copy.MOV"], 2)])
    eq("a still keeps one companion", p.count, 1)

    // in the pipeline: one asset, and the clip is not a duplicate
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pm-live-\(UUID().uuidString)/c.sqlite")
    guard let c = try? Catalog(url: tmp) else { check("opens", false); return }
    defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }
    try? c.transaction {
        try c.run("""
            INSERT INTO source(id, path, added_at) VALUES(1,'/L',0);
            INSERT INTO file(id, source_id, path, rel_path, size, mtime, kind, sha256, width, height,
                             captured_at, utc_offset, content_id, state)
              VALUES(1,1,'/L/0/A.heic','0/A.heic',2000,0,'image','s1',100,100,'2021:05:01 10:00:00','+08:00','CID-1','extracted');
            INSERT INTO file(id, source_id, path, rel_path, size, mtime, kind, sha256, width, height,
                             duration, frames, captured_at, content_id, state)
              VALUES(2,1,'/L/0/A_3.mov','0/A_3.mov',3000,0,'video','s2',100,100,2.5,X'00','2021:05:01 10:00:00','CID-1','extracted');
            """)
    }
    guard let rep = try? Pipeline.cluster(c, radius: 4) else { check("clusters", false); return }
    eq("a Live Photo is one photograph", rep.assets, 1)
    eq("and one Live Photo", rep.livePhotos, 1)
    eq("its clip is a companion", c.scalarInt("SELECT COUNT(*) FROM member WHERE role='companion';"), 1)
    eq("not a duplicate", c.scalarInt("SELECT COUNT(*) FROM member WHERE role='duplicate';"), 0)
    eq("so nothing is recoverable", c.scalarInt("SELECT SUM(wasted) FROM cluster;"), 0)
    eq("the still is kept", c.scalarInt("SELECT file_id FROM member WHERE role='canonical';"), 1)
    _ = try? Pipeline.resolve(c)
    let rec = Export.records(c).first
    eq("export names the clip as the companion", rec?.companion, "/L/0/A_3.mov")
    eq("and not as a duplicate", rec?.duplicates, [])
    eq("a Live Photo is not listed among duplicates", Decisions.list(c, .duplicates).total, 0)
    eq("but is among Live Photos", Decisions.list(c, .live).total, 1)
    if let a = Decisions.load(c, cluster: rec?.asset ?? 0) {
        eq("and says so", Decisions.identity(a).answer, "A Live Photo")
    }
}

func testExifTool() {
    print("\nexiftool, the lossless writer")
    guard let et = try? ExifTool() else { print("    (exiftool not installed — skipped)"); return }
    check("it starts, and reports a version", et.version != nil)
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pm-et-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let f = dir.appendingPathComponent("with space & 'quote'.jpg")
    writeJPEG(f, seed: 42, side: 256)
    let before = Extractor.extract(f, isImage: true)
    do {
        try et.write(f.path, [
            "EXIF:DateTimeOriginal": "2019:07:14 12:00:00", "EXIF:OffsetTimeOriginal": "+08:00",
            "XMP-xmp:CreateDate": "2019:07:14 12:00:00+08:00",
            "IPTC:DateCreated": "2019:07:14", "IPTC:TimeCreated": "12:00:00+08:00",
            "EXIF:GPSLatitude": "1.3", "EXIF:GPSLatitudeRef": "N",
            "EXIF:GPSLongitude": "103.8", "EXIF:GPSLongitudeRef": "E",
        ])
        check("writing reports success", true)
    } catch { check("writing reports success", false, "\(error)") }
    let back = (try? et.read(f.path, ["DateTimeOriginal", "OffsetTimeOriginal", "GPSLatitude", "XMP-xmp:CreateDate"])) ?? [:]
    eq("the capture date reads back", back["ExifIFD:DateTimeOriginal"], "2019:07:14 12:00:00")
    eq("so does its offset", back["ExifIFD:OffsetTimeOriginal"], "+08:00")
    eq("and the place", back["GPS:GPSLatitude"].flatMap(Double.init).map { ($0 * 10).rounded() / 10 }, 1.3)
    let after = Extractor.extract(f, isImage: true)
    eq("the pixels are untouched", after?.pixelHash, before?.pixelHash)
    check("while the bytes did change", after?.sha256 != before?.sha256)
    eq("our own reader now sees the date", after?.capturedAt, "2019:07:14 12:00:00")
    // a path that does not exist must fail loudly, not report success
    var failed = false
    do { try et.write(dir.appendingPathComponent("missing.jpg").path, ["EXIF:Artist": "x"]) } catch { failed = true }
    check("a failed write is an error", failed)
}

func testAct() {
    print("\nwriting a merged copy")
    guard ExifTool.locate() != nil else { print("    (exiftool not installed — skipped)"); return }
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pm-act-\(UUID().uuidString)")
    let src = dir.appendingPathComponent("src"), out = dir.appendingPathComponent("out")
    try? FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let t = Int(Resolver.epoch("2019:07:14 04:00:00", "+00:00")!)       // 12:00 at +08:00
    func sidecar(_ media: String, _ ts: Int, lat: Double? = nil, lon: Double? = nil) {
        var o: [String: Any] = ["photoTakenTime": ["timestamp": String(ts)]]
        if let lat, let lon { o["geoDataExif"] = ["latitude": lat, "longitude": lon] }
        try? JSONSerialization.data(withJSONObject: o).write(to: src.appendingPathComponent(media + ".supplemental-metadata.json"))
    }
    writeJPEG(src.appendingPathComponent("A.jpg"), seed: 1, side: 200, exifDate: "2019:07:14 12:00:00")
    sidecar("A.jpg", t, lat: 1.29, lon: 103.85)
    try? FileManager.default.copyItem(at: src.appendingPathComponent("A.jpg"), to: src.appendingPathComponent("A copy.jpg"))
    writeJPEG(src.appendingPathComponent("B.jpg"), seed: 2, side: 200)            // no date inside
    sidecar("B.jpg", t + 60, lat: 1.30, lon: 103.84)
    writeJPEG(src.appendingPathComponent("C.jpg"), seed: 3, side: 200)            // nothing at all
    func shas(_ d: URL) -> [String: String] {
        var m: [String: String] = [:]
        for f in (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? [] {
            if let data = FileManager.default.contents(atPath: d.appendingPathComponent(f).path) { m[f] = Extractor.sha(data) }
        }
        return m
    }
    let before = shas(src)

    guard let c = try? Catalog(url: dir.appendingPathComponent("c.sqlite")) else { check("opens", false); return }
    try? c.transaction { let st = try c.prepare("INSERT INTO source(path, added_at) VALUES(?,0);")
                         st.bind(1, src.path).done(); st.finalize() }
    _ = Ingest.scan(c); _ = Ingest.extract(c, workers: 2)
    _ = try? Pipeline.cluster(c, radius: 4); _ = try? Pipeline.resolve(c)

    // refusals first
    var refused = false
    do { _ = try Act.run(c, root: src.appendingPathComponent("inside").path, workers: 1) } catch { refused = true }
    check("a destination inside a source is refused", refused)

    guard let r = try? Act.run(c, root: out.path, workers: 2) else { check("runs", false); return }
    eq("one file per photograph — the duplicate is not written", r.written, 3)
    eq("nothing failed", r.failures.map(\.1), [])
    let a = out.appendingPathComponent("2019/07/20190714_120000.jpg")
    let b = out.appendingPathComponent("2019/07/20190714_120100.jpg")
    let undated = out.appendingPathComponent("Undated/C.jpg")
    for f in [a, b, undated] { check("written: \(f.path.dropFirst(out.path.count + 1))", FileManager.default.fileExists(atPath: f.path)) }
    let fb = Extractor.extract(b, isImage: true)
    eq("B now carries the date it only had in its sidecar", fb?.capturedAt, "2019:07:14 12:01:00")
    eq("and its offset", fb?.utcOffset, "+08:00")
    eq("and its place", fb?.lat.map { ($0 * 100).rounded() / 100 }, 1.3)
    let fa = Extractor.extract(a, isImage: true)
    eq("A gains the offset worked out from its clock and sidecar", fa?.utcOffset, "+08:00")
    let mt = (try? FileManager.default.attributesOfItem(atPath: a.path)[.modificationDate] as? Date)?.timeIntervalSince1970
    eq("the file date is the capture instant", mt.map { Int($0) }, t)
    eq("the originals are byte-for-byte untouched", shas(src), before)
    eq("every row verified", c.scalarInt("SELECT COUNT(*) FROM output WHERE state='verified' AND verified_at IS NOT NULL;"), 3)

    guard let again = try? Act.run(c, root: out.path, workers: 2) else { check("reruns", false); return }
    eq("running again writes nothing", again.written, 0)
    eq("and knows what is done", again.alreadyDone, 3)

    // a crash mid-file leaves only a partial, which the next run replaces
    try? Data("half".utf8).write(to: URL(fileURLWithPath: Act.partialPath(undated.path)))
    try? c.transaction { try c.run("UPDATE output SET state='planned' WHERE target LIKE 'Undated/%';") }
    try? FileManager.default.removeItem(at: undated)
    _ = try? Act.run(c, root: out.path, workers: 1)
    check("a crash leftover is replaced", !FileManager.default.fileExists(atPath: Act.partialPath(undated.path))
                                        && FileManager.default.fileExists(atPath: undated.path))

    // a crash after a file was moved into place, before it was recorded: known by its hash
    try? c.transaction { try c.run("UPDATE output SET state='committing' WHERE target LIKE 'Undated/%';") }
    try? Data("stray".utf8).write(to: URL(fileURLWithPath: Act.partialPath(a.path)))
    let resumed = try? Act.run(c, root: out.path, workers: 1)
    eq("a file moved in just before a crash is not written twice", resumed?.written, 0)
    check("nor left beside itself as _2", !FileManager.default.fileExists(atPath: out.appendingPathComponent("Undated/C_2.jpg").path))
    eq("it is verified from what is on disk", c.scalarInt("SELECT COUNT(*) FROM output WHERE state='verified';"), 3)
    check("and any half-written file is swept", !FileManager.default.fileExists(atPath: Act.partialPath(a.path)))

    // undo spares a file changed since it was written
    try? Data("edited by hand".utf8).write(to: b)
    let u = Act.undo(c, root: out.path)
    eq("undo removes what is still as written", u.removed, 2)
    eq("and leaves a file changed since", u.keptChanged, 1)
    check("so that file is still there", FileManager.default.fileExists(atPath: b.path))
    check("an emptied folder is tidied", !FileManager.default.fileExists(atPath: out.appendingPathComponent("Undated").path))
    eq("the originals are still untouched", shas(src), before)
}

func testAudit() {
    print("\nthe zone audit")
    func r(_ id: Int, _ t: String, _ off: String, _ la: Double, _ lo: Double, zone: String = "tag") -> Resolver.Resolved {
        var x = Resolver.Resolved(clusterID: id, localTime: t, timeSource: "exif", utcOffset: off, zoneSource: zone,
                                  lat: la, lon: lo, placeSource: "measured")
        x.instant = Resolver.epoch(t, off); return x
    }
    // consistent: nothing to report
    let ok = [r(1, "2019:07:14 12:00:00", "+08:00", 1.29, 103.85), r(2, "2019:07:14 12:10:00", "+08:00", 1.29, 103.85)]
    eq("a consistent day raises nothing", Audit.zones(ok).count, 0)
    // 10 minutes and 1 km apart, 3 hours apart in zone; the inferred one is blamed
    let bad = [r(1, "2019:07:14 12:00:00", "+08:00", 1.29, 103.85),
               r(2, "2019:07:14 09:10:00", "+05:00", 1.30, 103.86, zone: "nearest dated photo")]
    let f = Audit.zones(bad)
    eq("same place, same half hour, two zones", f.first?.kind, .samePlaceTwoZones)
    eq("the worked-out one is blamed", f.first?.clusterID, 2)
    // both read from their files: the neighbours decide, whichever was taken first
    let odd = [r(1, "2019:07:14 12:00:00", "+08:00", 1.29, 103.85), r(2, "2019:07:14 12:10:00", "+08:00", 1.29, 103.85),
               r(3, "2019:07:14 12:20:00", "+08:00", 1.29, 103.85), r(4, "2019:07:13 20:25:00", "-08:00", 1.29, 103.85)]
    eq("the odd one out is blamed, not the first taken", Audit.zones(odd).map(\.clusterID), [4])
    eq("with the offset its neighbours share", Audit.zones(odd).first?.expected, "+08:00")
    // far from any town (mid-Pacific), an even split cannot be settled
    let even = [r(1, "2019:07:14 12:00:00", "-10:00", 5.0, -160.0), r(2, "2019:07:14 13:10:00", "-09:00", 5.0, -160.0)]
    eq("an even split puts both to the person", Set(Audit.zones(even).map(\.clusterID)), [1, 2])
    // a whole session on home time outnumbers the one right photo; the town's clock settles it
    var session = (0..<5).map { r($0, "2019:07:13 20:0\($0):00", "-08:00", 1.29, 103.85) }
    session.append(r(9, "2019:07:14 12:03:00", "+08:00", 1.29, 103.85))
    let sf = Audit.zones(session)
    check("the town's clock outweighs a wrong majority", !sf.contains { $0.clusterID == 9 })
    eq("every photo on home time is flagged", Set(sf.map(\.clusterID)), Set(0..<5))
    eq("the clock check alone flags a lone wrong zone", Audit.zones([r(1, "2019:01:10 04:00:00", "-08:00", 1.29, 103.85)]).first?.kind, .placeClock)
    eq("with the offset clocks there showed", Audit.zones([r(1, "2019:01:10 04:00:00", "-08:00", 1.29, 103.85)]).first?.expected, "+08:00")
    eq("daylight saving is the town's, not a guess", Audit.zones([r(1, "2019:07:10 12:00:00", "+01:00", 38.7251, -9.1498),
                                                                r(2, "2019:01:10 12:00:00", "+00:00", 38.7251, -9.1498)]).count, 0)
    eq("a zone the person set is left alone", Audit.zones([r(1, "2019:01:10 04:00:00", "-08:00", 1.29, 103.85, zone: "you corrected it")]).count, 0)
    // a flight: far apart, so different zones are fine
    let flight = [r(1, "2019:07:14 12:00:00", "+08:00", 1.29, 103.85), r(2, "2019:07:14 06:20:00", "+02:00", 48.86, 2.35)]
    eq("far apart, different zones are no contradiction", Audit.zones(flight).count, 0)
    // the place disputes, where no town is near: three tagged neighbours agree, one inferred differs
    var many = (0..<3).map { r($0, "2019:07:1\($0) 12:00:00", "+08:00", 5.0, -160.0) }
    many.append(r(9, "2019:07:20 12:00:00", "+09:00", 5.01, -160.01, zone: "nearest dated photo"))
    eq("an offset the place disputes is flagged", Audit.zones(many).first { $0.clusterID == 9 }?.kind, .placeDisagrees)
    eq("with what the place records", Audit.zones(many).first?.expected, "+08:00")

    // correcting keeps the instant and moves the clock
    let wrong = input(1, claim("2018:03:10 01:15:30", off: "-08:00", lat: 1.2903, lon: 103.8520))
    let (fixed, st) = Resolver.resolve([wrong], fixes: [1: "+08:00"])
    eq("a correction moves the wall clock", fixed[0].localTime, "2018:03:10 17:15:30")
    eq("and keeps the instant", fixed[0].instant, Resolver.epoch("2018:03:10 01:15:30", "-08:00"))
    eq("and says who corrected it", fixed[0].zoneSource, "you corrected it")
    eq("counted", st.zoneCorrected, 1)
    let tags = Act.tags(isVideo: false, local: fixed[0].localTime, offset: fixed[0].utcOffset,
                        zoneSource: fixed[0].zoneSource, timeSource: fixed[0].timeSource, lat: nil, lon: nil,
                        placeSource: "measured", fileHasGPS: true, options: .init())
    eq("the merged copy writes the corrected clock", tags["EXIF:DateTimeOriginal"], "2018:03:10 17:15:30")
    eq("and the corrected offset", tags["EXIF:OffsetTimeOriginal"], "+08:00")
}

func testManual() {
    print("\nfilled in by hand")
    func near(_ a: (lat: Double, lon: Double)?, _ la: Double, _ lo: Double) -> Bool {
        guard let a else { return false }; return abs(a.lat - la) < 1e-4 && abs(a.lon - lo) < 1e-4
    }
    check("decimal pair", near(Manual.coordinate("38.7251, -9.1498"), 38.7251, -9.1498))
    check("space separated", near(Manual.coordinate("38.7251 -9.1498"), 38.7251, -9.1498))
    check("hemispheres", near(Manual.coordinate("33.87S 151.21E"), -33.87, 151.21))
    check("west is negative", near(Manual.coordinate("40.7128 N, 74.0060 W"), 40.7128, -74.006))
    check("degrees, minutes, seconds", near(Manual.coordinate("38°43'30\"N 9°8'59\"W"), 38.725, -9.149722))
    check("longitude first, when the letters say so", near(Manual.coordinate("9.1498W, 38.7251N"), 38.7251, -9.1498))
    check("negative decimals", near(Manual.coordinate("-33.87, 151.21"), -33.87, 151.21))
    check("a west longitude written first keeps its sign", near(Manual.coordinate("74.0060W 40.7128N"), 40.7128, -74.006))
    eq("out of range is refused", Manual.coordinate("95, 10") == nil, true)
    eq("(0, 0) is refused", Manual.coordinate("0, 0") == nil, true)
    eq("rubbish is refused", Manual.coordinate("Lisbon") == nil, true)

    // selection, as in Finder
    let order = [10, 11, 12, 13, 14]
    var sel = Manual.click([], anchor: nil, order: order, id: 11, command: false, shift: false)
    eq("a click selects one", sel.selected, [11])
    sel = Manual.click(sel.selected, anchor: sel.anchor, order: order, id: 13, command: false, shift: true)
    eq("⇧-click selects the range", sel.selected, [11, 12, 13])
    sel = Manual.click(sel.selected, anchor: sel.anchor, order: order, id: 12, command: true, shift: false)
    eq("⌘-click toggles one off", sel.selected, [11, 13])
    sel = Manual.click(sel.selected, anchor: sel.anchor, order: order, id: 14, command: true, shift: true)
    eq("⌘⇧-click adds a range", sel.selected, [11, 12, 13, 14])
    sel = Manual.click(sel.selected, anchor: sel.anchor, order: order, id: 10, command: false, shift: false)
    eq("a plain click starts over", sel.selected, [10])

    // precedence: an entry fills gaps and guesses, never evidence
    let noDate = input(1, claim(nil, mtime: 1_700_000_000))
    let exif = input(2, claim("2019:05:05 10:00:00", off: "+08:00", lat: 1, lon: 1))
    let inferredPlace = input(3, claim("2019:05:05 11:00:00", off: "+08:00"))   // takes #2's place by same-day
    let m: [Int: Manual.Entry] = [1: .init(day: "2018:03:04", lat: 1.29, lon: 103.85),
                                  2: .init(day: "2000:01:01", lat: 5, lon: 5),
                                  3: .init(day: nil, lat: 31.2, lon: 121.5)]
    let (r, st) = Resolver.resolve([noDate, exif, inferredPlace], manual: m)
    let one = r.first { $0.clusterID == 1 }!, two = r.first { $0.clusterID == 2 }!, three = r.first { $0.clusterID == 3 }!
    eq("an entered day replaces a file date", one.localTime, "2018:03:04 12:00:00")
    eq("and says whose it is", one.timeSource, "you entered the day")
    eq("an entered place fills a gap", one.placeSource, "you entered it")
    eq("an entry never overrules EXIF", two.localTime, "2019:05:05 10:00:00")
    eq("or measured GPS", two.placeSource, "measured")
    eq("but replaces a worked-out place", three.lat, 31.2)
    eq("counted", [st.timeEntered, st.placeEntered], [1, 2])

    // stored by content hash, through the real catalog
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pm-man-\(UUID().uuidString)/c.sqlite")
    guard let c = try? Catalog(url: tmp) else { check("opens", false); return }
    defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }
    try? c.transaction { try c.run("""
        INSERT INTO source(id, path, added_at) VALUES(1,'/x',0);
        INSERT INTO file(id, source_id, path, rel_path, size, mtime, kind, sha256, width, height, state)
          VALUES(1,1,'/x/a.jpg','a.jpg',10,1700000000,'image','sa',10,10,'extracted'),
                (2,1,'/x/b.jpg','b.jpg',10,1700000000,'image','sb',10,10,'extracted');
        """) }
    _ = try? Pipeline.cluster(c, radius: 0); _ = try? Pipeline.resolve(c)
    let ids = Manual.rows(c, .either).map(\.id)
    eq("both appear as needing a date and place", ids.count, 2)
    Manual.set(c, clusters: ids, day: "2015:08:01")
    Manual.set(c, clusters: [ids[0]], lat: 40.0, lon: 116.0)
    _ = try? Pipeline.resolve(c)
    eq("the batch got its day", Manual.rows(c, .date).count, 0)
    eq("one still lacks a place", Manual.rows(c, .place).count, 1)
    eq("both are listed as filled in", Manual.rows(c, .entered).count, 2)
    // accepting a worked-out place: a fact of its own, read as chosen, not typed
    Manual.confirm(c, places: [(cluster: ids[1], lat: 38.7, lon: -9.1)])
    let accepted = Manual.load(c)[ids[1]]
    eq("an accepted place is stored as confirmed", accepted?.confirmed, true)
    eq("and listed among what you settled", Manual.rows(c, .entered).count, 2)
    Manual.set(c, clusters: [ids[1]], lat: 40.0, lon: 116.0)
    eq("typing a place over it makes it an entry again", Manual.load(c)[ids[1]]?.confirmed, false)
    Manual.set(c, clusters: ids, clearDay: true, clearPlace: true)
    _ = try? Pipeline.resolve(c)
    eq("clearing restores the gap", Manual.rows(c, .date).count, 2)
    eq("and leaves nothing stored", c.scalarInt("SELECT COUNT(*) FROM manual_fact;"), 0)
    // what a merged copy would write for an entered day
    let t = Act.tags(isVideo: false, local: "2015:08:01 12:00:00", offset: nil, zoneSource: "none",
                     timeSource: "you entered the day", lat: 40, lon: 116, placeSource: "you entered it",
                     fileHasGPS: false, options: .init())
    eq("the entered day is written, at noon", t["EXIF:DateTimeOriginal"], "2015:08:01 12:00:00")
    eq("and the entered place", t["EXIF:GPSLatitude"], "40.0000000")
}

func testSnapshot() {
    print("\nundo: one snapshot for every choice")
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pm-undo-\(UUID().uuidString)/c.sqlite")
    guard let c = try? Catalog(url: tmp) else { check("opens", false); return }
    defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }
    try? c.transaction { try c.run("""
        INSERT INTO source(id, path, added_at, exclude) VALUES(1, '/x', 0, 'Screenshots');
        INSERT INTO zone_pick VALUES(18000, '+08:00', 1);
        INSERT INTO pair_decision VALUES('a', 'b', 1, 1);
        INSERT INTO keeper VALUES('k', 1);
        INSERT INTO zone_fix VALUES('z', '+08:00', 1);
        INSERT INTO manual_fact(sha, day, lat, lon, set_at) VALUES('m', '2015:08:01', 1.29, 103.85, 1);
        INSERT INTO place_rule(folder, lat, lon, label, created) VALUES('Trip', 1.5, 2.5, 'it''s here', 1);
        INSERT INTO setting VALUES('radius', '4');
        """) }
    func state() -> String {
        ["zone_pick", "pair_decision", "keeper", "zone_fix", "manual_fact", "place_rule", "setting"].map { t in
            var rows: [String] = []
            if let st = try? c.prepare("SELECT * FROM \(t) ORDER BY 1;") {
                while st.step() { rows.append((0..<8).map { st.text(Int32($0)) ?? "∅" }.joined(separator: "|")) }
                st.finalize()
            }
            return t + ":" + rows.joined(separator: ";")
        }.joined(separator: "\n") + "\nexclude:" + (c.setting("x") ?? "") + String(c.scalarInt("SELECT length(exclude) FROM source;"))
    }
    let before = state()
    let snap = Snapshot.take(c)
    try? c.transaction { try c.run("""
        DELETE FROM zone_pick; UPDATE keeper SET sha='changed'; DELETE FROM manual_fact;
        INSERT INTO place_rule(folder, lat, lon, label, created) VALUES('Other', 0, 0, 'x', 2);
        UPDATE setting SET value='8'; UPDATE source SET exclude = NULL;
        """) }
    check("the change took", state() != before)
    snap.apply(c)
    eq("restoring the snapshot restores every choice exactly", state(), before)
    eq("quotes in a value survive", c.scalarInt("SELECT COUNT(*) FROM place_rule WHERE label = 'it''s here';"), 1)
    eq("and the source's exclusions", c.scalarInt("SELECT COUNT(*) FROM source WHERE exclude = 'Screenshots';"), 1)
}

func testTidy() {
    print("\ntidy in place")
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pm-tidy-\(UUID().uuidString)")
    let src = dir.appendingPathComponent("src"), fakeTrash = dir.appendingPathComponent("trash")
    let lib = dir.appendingPathComponent("My.photoslibrary/originals")
    for d in [src, fakeTrash, lib] { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
    defer { try? FileManager.default.removeItem(at: dir) }
    writeJPEG(src.appendingPathComponent("a.jpg"), seed: 1)
    try? FileManager.default.copyItem(at: src.appendingPathComponent("a.jpg"), to: src.appendingPathComponent("a copy.jpg"))
    try? FileManager.default.copyItem(at: src.appendingPathComponent("a.jpg"), to: src.appendingPathComponent("a copy 2.jpg"))
    writeJPEG(lib.appendingPathComponent("L.jpg"), seed: 2)
    try? FileManager.default.copyItem(at: lib.appendingPathComponent("L.jpg"), to: lib.appendingPathComponent("L2.jpg"))
    guard let c = try? Catalog(url: dir.appendingPathComponent("c.sqlite")) else { check("opens", false); return }
    try? c.transaction { try c.run("INSERT INTO source(path, added_at) VALUES('\(src.path)',0),('\(lib.path)',0);") }
    _ = Ingest.scan(c); _ = Ingest.extract(c, workers: 2); _ = try? Pipeline.cluster(c, radius: 4)
    let plan = Tidy.plan(c)
    eq("two extra copies to tidy", plan.candidates.count, 2)
    eq("nothing inside a Photos library is touched", plan.inPhotosLibrary, 1)
    var trashed: [URL] = []
    let mover: (URL) throws -> URL = { u in
        let d = fakeTrash.appendingPathComponent(u.lastPathComponent)
        try FileManager.default.moveItem(at: u, to: d); trashed.append(d); return d
    }
    // the last copy is never moved: change the kept one first and nothing may go
    let kept = c.scalarInt("SELECT COUNT(*) FROM file;")
    let keptPath: String = {
        guard let st = try? c.prepare("SELECT f.path FROM member m JOIN file f ON f.id=m.file_id WHERE m.role='canonical' AND f.path LIKE '%/src/%';") else { return "" }
        defer { st.finalize() }; return st.step() ? (st.text(0) ?? "") : ""
    }()
    let original = FileManager.default.contents(atPath: keptPath)
    try? Data("changed".utf8).write(to: URL(fileURLWithPath: keptPath))
    var r = Tidy.run(c, trash: mover)
    eq("with its kept copy changed, nothing is trashed", r.moved, 0)
    try? original?.write(to: URL(fileURLWithPath: keptPath))
    r = Tidy.run(c, trash: mover)
    eq("the extra copies go to the Trash", r.moved, 2)
    check("and the kept copy stays", FileManager.default.fileExists(atPath: keptPath))
    eq("each move is recorded", c.scalarInt("SELECT COUNT(*) FROM trashed;"), 2)
    eq("tidying again finds nothing more", Tidy.plan(c).candidates.count, 0)
    // a crash after a move, before it was recorded: the row waits with no Trash location
    try? c.transaction { try c.run("UPDATE trashed SET trash_path = '' WHERE file_id = (SELECT MIN(file_id) FROM trashed);") }
    let back = Tidy.restore(c, trashFolder: { _ in fakeTrash })
    eq("restore puts them back, one found in the Trash by its hash", back.restored, 2)
    eq("where they were", (try? FileManager.default.contentsOfDirectory(atPath: src.path))?.count, 3)
    // a crash before the move: the row is dropped, the file never left
    try? c.transaction { try c.run("INSERT INTO trashed(file_id, sha, original, trash_path, at) SELECT id, sha256, path, '', 0 FROM file WHERE path LIKE '%a copy.jpg';") }
    Tidy.reconcile(c, trashFolder: { _ in fakeTrash })
    eq("a move that never happened is forgotten", c.scalarInt("SELECT COUNT(*) FROM trashed;"), 0)
    _ = kept
}

func testAreas() {
    print("\nworked-out places, by area")
    func row(_ id: Int, _ la: Double, _ lo: Double, _ t: String = "2019:07:14 12:00:00") -> Manual.Row {
        Manual.Row(id: id, path: "", localTime: t, timeSource: "exif", placeSource: "same day, same place", lat: la, lon: lo)
    }
    let rows = [row(1, 40.71, -74.00), row(2, 40.75, -73.98), row(3, 38.72, -9.15), row(4, 40.80, -73.95), row(5, 38.80, -9.20),
                row(6, 35.68, 139.69), Manual.Row(id: 7, path: "", localTime: nil, timeSource: "none", placeSource: "none")]
    let g = Manual.areas(rows)
    eq("three areas, largest first", g.map(\.count), [3, 2, 1])
    eq("New York's photographs together", Set(g[0].map(\.id)), [1, 2, 4])
    eq("a photograph without a place joins no area", g.flatMap { $0 }.count, 6)
    check("a worked-out place is one to look at", row(1, 0, 0).workedOut)
    check("an accepted one is not", !Manual.Row(id: 8, path: "", localTime: nil, timeSource: "exif", placeSource: "you confirmed it").workedOut)
    check("and reads as chosen, not inferred", !isInferred("you confirmed it"))
}

func testGazetteer() {
    print("\nplace names, offline")
    check("the places file is found and loaded", Gazetteer.places.count > 30_000)
    eq("Lisbon reads as Lisbon", Gazetteer.describe(38.7251, -9.1498), "Lisbon, Portugal")
    eq("Singapore by its coordinates", Gazetteer.describe(1.29, 103.85), "Singapore")
    eq("a little way out says near", Gazetteer.describe(65.68, -17.30), "near Akureyri, Iceland")
    eq("deep wilderness keeps its coordinates rather than a far town's name", Gazetteer.describe(44.6, -110.5), nil)
    eq("mid-ocean has no name", Gazetteer.describe(0.0, -140.0), nil)
    eq("a name finds the city", Gazetteer.search("Lisbon").first?.country, "Portugal")
    eq("so does a Japanese one", Gazetteer.search("東京").first?.name, "Tokyo")
    eq("and one typed without accents", Gazetteer.search("sao paulo").first?.name, "São Paulo")
    eq("the most populous comes first", Gazetteer.search("Springfield").first?.region, "Missouri")
    eq("one letter is not a search", Gazetteer.search("B").count, 0)
    // crossing the antimeridian: Fiji straddles ±180°
    check("the date line is not a wall", Gazetteer.nearest(-18.0, 179.99) != nil)
}

func testGuide() {
    print("\nthe guided review")
    eq("a clean collection needs nothing", Guide.cards(.init()).count, 0)
    var i = Guide.Inputs(); i.duplicates = 6; i.wastedBytes = 20_000_000; i.wrongZones = 104; i.wrongZoneDays = 51
    i.missingEither = 955; i.missingPlace = 955; i.editedCopies = 1
    let cs = Guide.cards(i)
    eq("wrong times come first — they are wrong data", cs.first?.kind, .wrongTime)
    eq("in plain words", cs.first?.title, "104 photos show the wrong time")
    check("and say how many land on the wrong day", cs.first?.detail.contains("51 of them") == true)
    eq("singular where it is one", cs.first { $0.kind == .edited }?.title, "1 edited copy")
    eq("order", cs.map(\.kind), [.wrongTime, .duplicates, .edited, .missing])
    var j = i; j.duplicates = 7
    check("a new duplicate changes the card's signature",
          Guide.cards(j).first { $0.kind == .duplicates }?.signature != cs.first { $0.kind == .duplicates }?.signature)
}

func testExport() {
    print("\nexport")
    eq("a plain value is left alone", Export.field("IMG_1.JPG"), "IMG_1.JPG")
    eq("a comma is quoted", Export.field("a,b.jpg"), "\"a,b.jpg\"")
    eq("a quote is doubled", Export.field("say \"cheese\".jpg"), "\"say \"\"cheese\"\".jpg\"")
    eq("a newline is quoted", Export.field("a\nb"), "\"a\nb\"")
    eq("a formula in a path is defused", Export.field("=HYPERLINK(1)", defuse: true), "\"'=HYPERLINK(1)\"")
    // found on real data: the guard once turned every western offset into '-07:00
    let west = Export.Record(asset: 1, kept: "/a.jpg", duplicates: [], recoverableBytes: 0,
                             localTime: nil, utcOffset: "-07:00", instantUTC: nil,
                             timeSource: "exif", zoneSource: "tag", latitude: 37.7,
                             longitude: -122.4, placeSource: "measured")
    let row = Export.csv([west]).components(separatedBy: "\r\n")[1]
    check("a negative offset survives export", row.contains(",-07:00,"))
    check("a western longitude survives export", row.contains(",-122.400000,"))
    eq("exif time becomes ISO", Export.isoLocal("2021:03:07 14:22:31"), "2021-03-07T14:22:31")

    let rec = Export.Record(asset: 7, kept: "/p/a,1.jpg", duplicates: ["/p/b.jpg", "/p/c.jpg"],
                            recoverableBytes: 10, localTime: "2021-03-07T14:22:31",
                            utcOffset: nil, instantUTC: nil, timeSource: "exif",
                            zoneSource: "none", latitude: nil, longitude: nil, placeSource: "none")
    let lines = Export.csv([rec]).components(separatedBy: "\r\n")
    eq("header row first", lines.first?.hasPrefix("asset,kept,duplicates"), true)
    check("duplicates share one quoted cell", lines[1].contains("\"/p/b.jpg\n/p/c.jpg\""))
    check("no zone means no instant, not a UTC guess", lines[1].contains(",,,exif,none"))
    if let d = try? Export.json([rec]),
       let back = try? JSONDecoder().decode([Export.Record].self, from: d) {
        eq("json round-trips", back, [rec])
    } else { check("json encodes", false) }
}

func testDecisions() {
    print("\nexplaining a decision")
    func asset(_ files: [Decisions.FileClaim], _ r: Resolver.Resolved, method: String = "single") -> Decisions.Asset {
        .init(clusterID: 1, method: method, files: files, resolution: r)
    }
    func file(_ id: Int, _ t: String?, lat: Double? = nil) -> Decisions.FileClaim {
        .init(id: id, path: "/p/IMG_\(id).JPG", role: id == 1 ? "canonical" : "duplicate",
              reason: id == 1 ? "kept: 4032×3024, 3000 KB" : "duplicate", capturedAt: t,
              utcOffset: nil, lat: lat, lon: lat, model: nil, bytes: 1, width: 1, height: 1)
    }
    var r = Resolver.Resolved(clusterID: 1, localTime: "2019:07:04 18:30:00", timeSource: "exif")

    // copies that disagree about the date: say so, and say which won and why
    let t = Decisions.time(asset([file(1, "2019:07:04 18:30:00"), file(2, "2020:01:02 09:00:00")], r, method: "similar"))
    check("disagreeing copies are named", t.why.contains("disagree") && t.why.contains("2 Jan 2020"))
    check("and the rule is stated", t.why.contains("earliest"))

    r.timeSource = "mtime (unreliable)"
    let m = Decisions.time(asset([file(1, nil)], r))
    eq("a file date is inferred", m.provenance, .inferred)
    check("and it warns what a file date usually is", m.why.contains("copied or exported"))

    r.zoneSource = "nearest dated photo"; r.utcOffset = "+02:00"
    let z = Decisions.zone(asset([file(1, nil)], r))
    eq("a borrowed zone is inferred", z.provenance, .inferred)
    check("and names the two-day window", z.why.contains("two days"))
    r.zoneSource = "you chose it"
    eq("a chosen zone is credited to the person", Decisions.zone(asset([file(1, nil)], r)).provenance, .chosen)

    r.lat = 1; r.lon = 2; r.placeSource = "nearest fix, 12 min"
    var params = Resolver.Params(); params.travelMinutes = 45
    let p = Decisions.place(asset([file(1, nil)], r), params)
    check("a borrowed place gives the gap and the bound it used",
          p.why.contains("12 min") && p.why.contains("45-minute"))
    r.placeSource = "same day, same place"; params.dayRadiusKM = 10
    check("a same-day place gives the radius it used",
          Decisions.place(asset([file(1, nil)], r), params).why.contains("10 km"))
}

func testCatalog() {
    print("\ncatalog")
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pm-test-\(UUID().uuidString)/catalog.sqlite")
    guard let c = try? Catalog(url: tmp) else { check("opens", false); return }
    check("opens and migrates", true)
    try? c.transaction {
        let st = try c.prepare("INSERT INTO source(path, added_at) VALUES(?,?);")
        st.bind(1, "/tmp/x").bind(2, 1.0).done(); st.finalize()
    }
    eq("insert + read back", c.scalarInt("SELECT COUNT(*) FROM source;"), 1)
    eq("last rowid", c.lastInsertRowID > 0, true)
    // rollback on error must leave nothing behind
    try? c.transaction {
        let st = try c.prepare("INSERT INTO source(path, added_at) VALUES(?,?);")
        st.bind(1, "/tmp/y").bind(2, 1.0).done(); st.finalize()
        throw Catalog.Err.sql("deliberate")
    }
    eq("transaction rolls back on throw", c.scalarInt("SELECT COUNT(*) FROM source;"), 1)
    try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent())
}

// ---------------------------------------------------------------- main

let args = CommandLine.arguments
// Unbuffered, so a hang shows where it is: block-buffered output to a file stops at
// an arbitrary flush boundary, not at the test that is stuck.
setvbuf(stdout, nil, _IONBF, 0)

// `analyse <folder> [radius]` runs the real pipeline into the app's catalog.
// `sweep <folder> [limit]`    reports the radius dial's effect on this collection.
if args.count > 2, args[1] == "analyse" {
    let r = args.count > 3 ? Int(args[3]) ?? 4 : 4
    print("analysing \(args[2]) at radius \(r)")
    try Integration.run(folder: URL(fileURLWithPath: args[2]), radius: r,
                        catalogURL: Integration.appCatalogURL(), limit: nil)
    print("\nwritten to \(Integration.appCatalogURL().path)")
    exit(0)
}
// `resume` runs the app's own stages on the app's catalog — scan, read what is
// unread, group, resolve — without wiping anything, exactly as ⌘R does.
if args.count > 1, args[1] == "resume" {
    let c = try Catalog(url: Integration.appCatalogURL())
    let t0 = Date()
    let sr = Ingest.scan(c)
    let er = Ingest.extract(c, workers: Ingest.workers)
    let rep = try Pipeline.cluster(c, radius: Pipeline.radius(c))
    let res = try Pipeline.resolve(c)
    let s = res.stats, n = max(1, res.resolved.count)
    print("scan: \(sr.seen) seen, \(sr.added) new, \(sr.changed) changed, \(sr.removed) gone")
    print(String(format: "read: %d (%d could not be opened) in %.0fs", er.done, er.failed, Date().timeIntervalSince(t0)))
    print("groups: \(rep.assets) assets, \(rep.duplicates) duplicates")
    print("time: exif \(s.timeFromExif) · filename \(s.timeFromName) · instant \(s.timeFromInstant) · mtime \(s.timeFromMtime)")
    print("zone: tag \(s.zoneFromTag) · derived \(s.zoneDerived) · place \(s.zoneFromPlace) · neighbour \(s.zoneFromNeighbour) · yours \(s.zoneFromYou)  → \(s.zoned * 100 / n)% zoned")
    exit(0)
}
// `vdet <file>` — is video fingerprinting deterministic? (a diagnostic)
if args.count > 2, args[1] == "vdet" {
    let u = URL(fileURLWithPath: args[2])
    for _ in 0..<3 {
        if let v = VideoExtractor.extract(u) { print(v.duration, v.frames.map { String($0, radix: 16) }) }
    }
    exit(0)
}
// `audit` — zone contradictions in the app's catalog
if args.count > 1, args[1] == "audit" {
    let c = try Catalog(url: Integration.appCatalogURL())
    let res = Resolver.resolve(Pipeline.claims(c), picks: Pipeline.picks(c), params: Pipeline.params(c)).out
    let f = Audit.zones(res)
    print("\(f.count) contradictions")
    // `audit dump` lists every flagged asset, for comparing two runs
    if args.count > 2, args[2] == "dump" { for x in f.sorted(by: { $0.clusterID < $1.clusterID }) { print("\(x.clusterID) \(x.offset) \(x.expected) \(x.kind.rawValue)") }; exit(0) }
    let src = Dictionary(grouping: f, by: { x in res.first { $0.clusterID == x.clusterID }?.zoneSource ?? "?" }).mapValues(\.count)
    print("blamed zone came from:", src.sorted { $0.value > $1.value }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", "))
    for x in f.prefix(12) { print("  [\(x.kind.rawValue)] asset \(x.clusterID) vs \(x.other ?? 0): \(x.offset) vs \(x.expected) — \(x.note)") }
    let kinds = Dictionary(grouping: f, by: { "\($0.offset) vs \($0.expected)" }).mapValues(\.count)
    var years: [String: Int] = [:], models: [String: Int] = [:], dayChanges = 0
    for x in f {
        guard let r = res.first(where: { $0.clusterID == x.clusterID }), let t = r.localTime, let i = r.instant else { continue }
        years[String(t.prefix(4)), default: 0] += 1
        let fixed = Resolver.wallClock(i, offset: Resolver.offsetSeconds(x.expected))
        if fixed.prefix(10) != t.prefix(10) { dayChanges += 1 }
    }
    if let st = try? c.prepare("SELECT COALESCE(f.model,'(no camera)') FROM member m JOIN file f ON f.id=m.file_id WHERE m.role='canonical' AND m.cluster_id IN (\(f.map { String($0.clusterID) }.joined(separator: ",")));") {
        while st.step() { models[st.text(0) ?? "", default: 0] += 1 }
        st.finalize()
    }
    print("years:", years.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", "))
    print("cameras:", models.sorted { $0.value > $1.value }.prefix(5).map { "\($0.key) ×\($0.value)" }.joined(separator: ", "))
    print("corrected, \(dayChanges) of \(f.count) would move to a different calendar day")
    print("by pattern:", kinds.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key) ×\($0.value)" }.joined(separator: ", "))
    exit(0)
}
// Crash tests (Tests/crash_test.sh), one step each on an existing catalog so a run
// can be killed and the next resumed:
//   prep <folder> <catalog>      read, group and resolve into a new catalog
//   actc <catalog> <out>         write the clean library (resumes)
//   undoc <catalog> <out>        remove what was written
//   tidyc <catalog> <trash-dir>  move duplicates into <trash-dir> (a stand-in Trash)
//   restorec <catalog> <trash-dir>  put them back
if args.count > 3, args[1] == "prep" {
    let catURL = URL(fileURLWithPath: args[3]); try? FileManager.default.removeItem(at: catURL)
    let c = try Catalog(url: catURL)
    try c.transaction { let st = try c.prepare("INSERT INTO source(path, added_at) VALUES(?,0);")
                        st.bind(1, args[2]).done(); st.finalize() }
    _ = Ingest.scan(c); _ = Ingest.extract(c, workers: Ingest.workers)
    let rep = try Pipeline.cluster(c, radius: 4); _ = try Pipeline.resolve(c)
    print("\(rep.assets) assets, \(rep.livePhotos) live, \(rep.duplicates) duplicates"); exit(0)
}
if args.count > 3, args[1] == "actc" {
    let r = try Act.run(try Catalog(url: URL(fileURLWithPath: args[2])), root: args[3], workers: Ingest.workers)
    print("planned \(r.planned), written \(r.written), already \(r.alreadyDone), failed \(r.failed)")
    for (f, why) in r.failures { print("  FAILED \((f as NSString).lastPathComponent): \(why)") }
    exit(0)
}
if args.count > 3, args[1] == "undoc" {
    let r = Act.undo(try Catalog(url: URL(fileURLWithPath: args[2])), root: args[3])
    print("removed \(r.removed), changed \(r.keptChanged), missing \(r.missing)"); exit(0)
}
if args.count > 3, args[1] == "tidyc" {
    let dir = URL(fileURLWithPath: args[3])
    let r = Tidy.run(try Catalog(url: URL(fileURLWithPath: args[2])), trash: { u in
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var d = dir.appendingPathComponent(u.lastPathComponent), k = 2
        while FileManager.default.fileExists(atPath: d.path) {
            d = dir.appendingPathComponent(u.deletingPathExtension().lastPathComponent + " \(k)." + u.pathExtension); k += 1
        }
        try FileManager.default.moveItem(at: u, to: d); return d
    }, trashFolder: { _ in dir })
    print("moved \(r.moved), skipped \(r.skipped)"); for w in r.reasons { print("  " + w) }; exit(0)
}
if args.count > 3, args[1] == "restorec" {
    let dir = URL(fileURLWithPath: args[3])
    let r = Tidy.restore(try Catalog(url: URL(fileURLWithPath: args[2])), trashFolder: { _ in dir })
    print("restored \(r.restored), missing \(r.missing), occupied \(r.occupied)"); exit(0)
}

// `known <folder> <catalog> <out>` — the whole pipeline on a folder into a given
// catalog, then a clean library into <out>; audit findings to <catalog>.audit.json.
// Scored by Tests/check_known.py against the answers Tests/known_library.py wrote.
if args.count > 4, args[1] == "known" {
    let catURL = URL(fileURLWithPath: args[3])
    try? FileManager.default.removeItem(at: catURL)
    let c = try Catalog(url: catURL)
    try c.transaction { let st = try c.prepare("INSERT INTO source(path, added_at) VALUES(?,0);")
                        st.bind(1, args[2]).done(); st.finalize() }
    let sr = Ingest.scan(c); let er = Ingest.extract(c, workers: Ingest.workers)
    let rep = try Pipeline.cluster(c, radius: 4)
    let res = try Pipeline.resolve(c)
    let findings = Audit.zones(res.resolved).map { ["cluster": $0.clusterID, "offset": $0.offset,
                                                     "expected": $0.expected, "kind": $0.kind.rawValue] as [String: Any] }
    try JSONSerialization.data(withJSONObject: findings).write(to: URL(fileURLWithPath: args[3] + ".audit.json"))
    let act = try Act.run(c, root: args[4], workers: Ingest.workers)
    print("scanned \(sr.seen), read \(er.done) (\(er.failed) failed) → \(rep.assets) assets, \(rep.livePhotos) live, \(rep.duplicates) duplicates")
    print("wrote \(act.written), failed \(act.failed)")
    for (f, why) in act.failures { print("  FAILED \((f as NSString).lastPathComponent): \(why)") }
    exit(0)
}
// `plan` — what a merged copy of the app's catalog would contain. Writes nothing.
if args.count > 1, args[1] == "plan" {
    let c = try Catalog(url: Integration.appCatalogURL())
    let s = Act.summary(c, options: .init())
    print("\(s.photographs) photographs + \(s.clips) live clips = \(s.files) files, \(byteString(s.bytes))")
    print("dates filled \(s.datesFilled) · places from sidecars \(s.placesRead) · places worked out \(s.placesWorkedOut) · zones worked out \(s.zonesWorkedOut)")
    print("undated \(s.undated) · named in UTC \(s.inUTC)")
    let items = Act.plan(c)
    // a suffix *after* the HHMMSS field — the time itself also ends in _digits
    let collisions = items.filter { $0.target.range(of: #"_\d{6}Z?_\d+\.[a-z0-9]+$"#, options: .regularExpression) != nil }.count
    print("same-second collisions given _N: \(collisions); distinct targets: \(Set(items.map { $0.target.lowercased() }).count) of \(items.count)")
    s.sample.forEach { print("  " + $0) }
    let sp = Act.space(c, root: NSTemporaryDirectory() + "photomerge-plan-probe")
    print("space: need \(byteString(sp.need)), free \(byteString(sp.free)) → \(sp.need <= sp.free ? "fits" : "refused")")
    exit(0)
}
// `act <folder> <out>` runs the whole thing on a folder into a fresh catalog, then
// writes the merged copy to <out>: the end-to-end check on real files.
if args.count > 3, args[1] == "act" {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pm-act-\(UUID().uuidString)/c.sqlite")
    let c = try Catalog(url: tmp)
    try c.transaction { let st = try c.prepare("INSERT INTO source(path, added_at) VALUES(?,0);")
                        st.bind(1, args[2]).done(); st.finalize() }
    _ = Ingest.scan(c); _ = Ingest.extract(c, workers: Ingest.workers)
    let rep = try Pipeline.cluster(c, radius: 4); _ = try Pipeline.resolve(c)
    print("\(rep.assets) photographs (\(rep.livePhotos) Live Photos, \(rep.duplicates) duplicates)")
    let t0 = Date()
    let r = try Act.run(c, root: args[3], workers: Ingest.workers)
    print(String(format: "written %d, failed %d in %.1fs", r.written, r.failed, Date().timeIntervalSince(t0)))
    for (f, why) in r.failures.prefix(10) { print("  FAILED \((f as NSString).lastPathComponent): \(why)") }
    exit(0)
}
// `regroup [radius]` re-runs grouping and resolution on the app's catalog, no rescan.
if args.count > 1, args[1] == "regroup" {
    let c = try Catalog(url: Integration.appCatalogURL())
    let r = args.count > 2 ? Int(args[2]) ?? Pipeline.radius(c) : Pipeline.radius(c)
    let rep = try Pipeline.cluster(c, radius: r)
    try Pipeline.resolve(c)
    print("radius \(r): \(rep.assets) assets, \(rep.duplicates) duplicates, longest chain \(rep.longestChain)")
    if let st = try? c.prepare("SELECT outcome, COUNT(*) FROM pair GROUP BY 1 ORDER BY 2 DESC;") {
        while st.step() { print("  \(st.text(0) ?? "")  \(st.int(1))") }
        st.finalize()
    }
    exit(0)
}
// `preview` times the dial previews on the app's catalog — they must feel live.
if args.count > 1, args[1] == "preview" {
    let c = try Catalog(url: Integration.appCatalogURL())
    var t = Date()
    let items = Pipeline.imageItems(c)
    print(String(format: "load %d items          %.2fs", items.count, Date().timeIntervalSince(t)))
    t = Date()
    let pv = Preview.radii(items, [0, 2, 4, 6, 8])
    print(String(format: "5 radii                  %.2fs", Date().timeIntervalSince(t)))
    for r in pv.rows {
        print("  r\(r.radius): dupes \(r.duplicates) merged \(r.merged) review \(r.variants) rejected \(r.rejected) bursts \(r.bursts) chain \(r.longestChain)")
    }
    t = Date()
    let inputs = Pipeline.claims(c)
    let now = Resolver.resolve(inputs, picks: Pipeline.picks(c)).out
    print(String(format: "load + resolve           %.2fs", Date().timeIntervalSince(t)))
    for (d, m) in [(25.0, 60.0), (10, 30), (50, 120), (100, 240)] {
        t = Date()
        var p = Resolver.Params(); p.dayRadiusKM = d; p.travelMinutes = m
        let pr = Preview.places(inputs, picks: Pipeline.picks(c), current: now, candidate: p)
        let g = pr.changes.filter { $0.kind == .gained }.count, l = pr.changes.filter { $0.kind == .lost }.count
        print(String(format: "  %3.0f km / %3.0f min: located %d (+%d −%d, %d moved)   %.2fs",
                     d, m, pr.located, g, l, pr.changes.count - g - l, Date().timeIntervalSince(t)))
    }
    exit(0)
}
// `backtest [catalog]` hides the zone on days that have one and re-derives it.
if args.count > 1, args[1] == "backtest" {
    let url = args.count > 2 ? URL(fileURLWithPath: args[2]) : Integration.appCatalogURL()
    print("back-testing the ballot against \(url.path)")
    if args.count > 3, args[3] == "sweep" { try Backtest.sweepDaylight(url) }
    else { Backtest.report(try Backtest.run(url)) }
    exit(0)
}
if args.count > 2, args[1] == "sweep" {
    let lim = args.count > 3 ? Int(args[3]) : nil
    try Integration.radiusSweep(folder: URL(fileURLWithPath: args[2]), limit: lim)
    exit(0)
}

let root = args.count > 1 ? URL(fileURLWithPath: args[1]) : nil

print("PhotoMerge engine tests")
testBKTree()
testCascade()
testVideo()
testResolver()
testBallot()
testCatalog()
testPipeline()
testDecisions()
testExport()
testPreview()
testPreviewOrder()
testIngest()
testNamesAndSidecars()
testInstants()
testTakeoutEndToEnd()
testCompanions()
testExifTool()
testAct()
testAudit()
testManual()
testGuide()
testSnapshot()
testTidy()
testAreas()
testGazetteer()
if let root {
    testSniff(root)
    testExtract(root)
} else {
    print("\n(pass a folder to also run the real-file tests)")
}

print("\n\(checks - failures)/\(checks) passed")
exit(failures == 0 ? 0 : 1)
