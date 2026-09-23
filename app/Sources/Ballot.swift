import Foundation

/// When a whole day has no timezone — no offset tag, no measured fix, no located
/// neighbour in range — score every real offset by independent local signals and
/// present a ranked ballot (PLAN §7.4).
///
/// v1 **proposes only**. Nothing is written, and a ballot that cannot separate its
/// top two candidates says so rather than picking one (INHERITED §2.20).
enum Ballot {

    /// Offsets that real places actually use, including the quarter- and half-hour
    /// ones. Scoring all 24 integers would invent candidates nobody lives in.
    static let candidates: [Double] = [
        -12, -11, -10, -9.5, -9, -8, -7, -6, -5, -4, -3.5, -3, -2, -1,
        0, 1, 2, 3, 3.5, 4, 4.5, 5, 5.5, 5.75, 6, 6.5, 7, 8, 8.75,
        9, 9.5, 10, 10.5, 11, 12, 12.75, 13, 14,
    ].map { $0 * 3600 }

    // MARK: inputs

    struct Photo {
        var secondsOfDay: Int       // wall clock, as recorded
        var ev: Double?             // exposure value, the light meter
        var epochMillisName: Double?  // an absolute timestamp from the filename
    }

    struct Context {
        var day: Int                          // days since epoch
        var photos: [Photo]
        /// Longitude of the day's place, if anything is known. An *inferred* place is
        /// allowed here because a ballot only proposes; it may never certify (§2.16).
        var longitude: Double?
        var longitudeIsMeasured: Bool = false
        /// Offset of the nearest day that does have one, and how many days away.
        var neighbourOffset: Double?
        var neighbourGapDays: Int = 999
        /// What this camera body used most within a few days either side.
        var deviceOffset: Double?
        var deviceSamples: Int = 0
    }

    // MARK: signals

    struct Signal {
        let name: String
        let detail: String
        /// 0…1. Higher is better. A signal that cannot speak returns nil instead of 0.5.
        let score: (Double) -> Double?
    }

    /// The daylight signal's shape. `daylightPlateau` hours either side of the
    /// implied offset score full marks; beyond `daylightCutoff` it scores nothing.
    /// A plateau rather than a peak because the centre of a day's *photography* is
    /// not the centre of its *daylight* — people shoot in the afternoon — so this
    /// signal can rule a candidate out but must not be trusted to rank.
    /// Set to 0/0 to switch the signal off.
    ///
    /// 4 and 12 are measurements, not preferences: on a 1,354-day back-test a
    /// narrower shape ranked worse than having no daylight signal at all, while
    /// this one keeps the truth among the three offered 95% of the time and halves
    /// how often the ballot is confidently wrong. See `./test.sh backtest … sweep`.
    static var daylightPlateau = 4.0
    static var daylightCutoff = 12.0

    /// Waking hours. Outside this, a day of photographs is implausible.
    static var wakingStart = 7.0
    static var wakingEnd = 24.0

    static func signals(_ ctx: Context) -> [Signal] {
        var out: [Signal] = []

        // 1. neighbour continuity — strongest when the gap is short
        if let n = ctx.neighbourOffset, ctx.neighbourGapDays <= 14 {
            let gap = Double(ctx.neighbourGapDays)
            out.append(Signal(
                name: "Neighbouring day",
                detail: "the nearest day with a known zone is \(ctx.neighbourGapDays) day\(ctx.neighbourGapDays == 1 ? "" : "s") away, at \(Resolver.offsetString(n))",
                score: { cand in
                    // a day next door is almost certainly the same zone; a fortnight
                    // away could be a different continent
                    let hoursApart = abs(cand - n) / 3600
                    let trust = max(0.15, 1 - gap / 14)
                    return max(0, 1 - hoursApart / 12) * trust + (1 - trust) * 0.5
                }))
        }

        // 2. diurnal plausibility — do the resulting local times look like a day?
        let sods = ctx.photos.map(\.secondsOfDay)
        if sods.count >= 3 {
            out.append(Signal(
                name: "Time of day",
                detail: "\(sods.count) photographs; a day's photography falls in waking hours",
                score: { _ in
                    // The wall clock IS the local time. This signal therefore judges
                    // the *recorded* clock, not the candidate — it can only reject a
                    // day whose clock is implausible under any zone, so it abstains.
                    nil
                }))
        }

        // 3. the daylight curve — the one signal that needs no other photo located
        if let lon = ctx.longitude, daylightCutoff > 0 {
            let bright = ctx.photos.compactMap { p -> (Double, Double)? in
                guard let ev = p.ev else { return nil }
                return (Double(p.secondsOfDay) / 3600, ev)
            }
            if bright.count >= 4 {
                // EV-weighted centre of the day's light: the brighter the frame, the
                // nearer it sits to solar noon.
                let maxEV = bright.map(\.1).max() ?? 0
                let weights = bright.map { max(0, $0.1 - (maxEV - 6)) }   // top ~6 stops
                let total = weights.reduce(0, +)
                if total > 0 {
                    let centre = zip(bright, weights).reduce(0.0) { $0 + $1.0.0 * $1.1 } / total
                    // Solar noon happens at UTC 12 − lon/15, so in a zone with offset o
                    // it falls at local 12 − lon/15 + o. The observed centre is local.
                    let implied = (centre - 12 + lon / 15) * 3600
                    out.append(Signal(
                        name: "Daylight",
                        detail: String(format: "the day's light peaks at %02d:%02d local, which puts solar noon at %@",
                                       Int(centre), Int((centre - floor(centre)) * 60),
                                       Resolver.offsetString(implied)),
                        score: { cand in
                            let hoursOff = abs(cand - implied) / 3600
                            // A barely-sloped plateau, not a flat one: inside the
                            // window this must not out-rank real evidence, but it
                            // still has to order the ties it creates, and the sun's
                            // own position is the only meaningful direction to
                            // order them in.
                            if hoursOff <= daylightPlateau {
                                return 1 - 0.05 * (hoursOff / daylightPlateau)
                            }
                            let span = daylightCutoff - daylightPlateau
                            return max(0, 1 - (hoursOff - daylightPlateau) / span)
                        }))
                }
            }
        }

        // 4. device habit — a phone usually carries a zone, so its own history is good
        if let d = ctx.deviceOffset, ctx.deviceSamples >= 3 {
            out.append(Signal(
                name: "This camera",
                detail: "used \(Resolver.offsetString(d)) on \(ctx.deviceSamples) nearby days",
                score: { cand in abs(cand - d) < 1 ? 1.0 : max(0, 1 - abs(cand - d) / 3600 / 12) }))
        }

        // 5. an absolute timestamp in the filename pins the offset outright
        if let ms = ctx.photos.compactMap(\.epochMillisName).first,
           let sod = ctx.photos.first(where: { $0.epochMillisName != nil })?.secondsOfDay {
            let utcSod = (ms / 1000).truncatingRemainder(dividingBy: 86400)
            var implied = Double(sod) - utcSod
            if implied > 43200 { implied -= 86400 }
            if implied < -43200 { implied += 86400 }
            out.append(Signal(
                name: "Filename",
                detail: "an epoch-millisecond filename fixes the instant, implying \(Resolver.offsetString(implied))",
                score: { cand in abs(cand - implied) < 900 ? 1.0 : 0.0 }))
        }

        return out
    }

    // MARK: the ballot

    struct Candidate {
        let offset: Double
        let score: Double
        /// Per-signal scores, so the UI can show *why* rather than a blended number.
        let perSignal: [(String, Double)]
        var offsetString: String { Resolver.offsetString(offset) }
    }

    struct Result {
        var ranked: [Candidate] = []
        var signals: [String] = []          // what spoke, in words
        /// True when the top two are too close to separate. A refusal, not a failure.
        var indistinguishable: Bool = false
        var margin: Double = 0
        var usable: Bool { !ranked.isEmpty && !indistinguishable }
    }

    /// Below this, the top candidate is not offered at all.
    static var confidenceFloor = 0.45
    /// Two candidates within this of each other cannot be separated.
    static var separationMargin = 0.08

    static func rank(_ ctx: Context) -> Result {
        var r = Result()
        let sigs = signals(ctx).filter { s in candidates.contains { s.score($0) != nil } }
        guard !sigs.isEmpty else { return r }
        r.signals = sigs.map { "\($0.name) — \($0.detail)" }

        var scored: [Candidate] = []
        for cand in candidates {
            var per: [(String, Double)] = []
            var sum = 0.0, n = 0.0
            for s in sigs {
                guard let v = s.score(cand) else { continue }
                per.append((s.name, v))
                sum += v; n += 1
            }
            guard n > 0 else { continue }
            scored.append(Candidate(offset: cand, score: sum / n, perSignal: per))
        }
        // Weights are deliberately equal: they ship unblended until back-testing on
        // days whose zone IS known says how to combine them (PLAN §15.4). A confident
        // single number from unvalidated weights is the failure mode to avoid.
        // Deterministic: Swift's sort is not stable, and two candidates scoring
        // the same must not swap places between runs of the same collection.
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset }
        r.ranked = Array(scored.prefix(3))

        if let best = r.ranked.first {
            if best.score < confidenceFloor { r.indistinguishable = true }
            if r.ranked.count > 1 {
                r.margin = best.score - r.ranked[1].score
                if r.margin < separationMargin { r.indistinguishable = true }
            }
        }
        return r
    }

    /// An epoch-millisecond filename, as Android and WeChat exports produce:
    /// `mmexport1500000000000.jpg`, `1500000000000.jpg`.
    static func epochMillisFromName(_ name: String) -> Double? {
        var digits = ""
        for ch in name {
            if ch.isNumber { digits.append(ch) }
            else if !digits.isEmpty { break }
        }
        // 13 digits ≈ 2001…2286 in milliseconds
        guard digits.count == 13, let v = Double(digits) else { return nil }
        let seconds = v / 1000
        return seconds > 978_307_200 && seconds < 9_999_999_999 ? v : nil
    }
}
