import Foundation

/// M6's exit criterion (PLAN §11): on days whose zone *is* known, hide it and
/// re-derive it from the ballot. The top pick must be right at least 90% of the
/// time, and it must never be *silently* wrong — a wrong answer the ballot offered
/// confidently is a much worse failure than one it refused to separate.
///
/// This reads a catalog the app has already filled. It writes nothing.
enum Backtest {

    struct Score {
        var days = 0                // days with a known zone and enough evidence
        var contradictory = 0       // days whose own files disagree: not scorable
        var skipped = 0             // no signal spoke: the ballot stayed silent
        var top = 0                 // top candidate exactly right
        var offered = 0             // right answer somewhere in the three offered
        var confidentlyWrong = 0    // top wrong AND the ballot claimed it could tell
        var refusedButRight = 0     // top right, but the ballot refused to commit
        var committed = 0           // days the ballot said it could tell apart
        var committedRight = 0      // …and was right. This is the number that matters.
        var errors: [Double: Int] = [:]   // hours off, for the ones it missed
        /// How often each signal spoke. A signal that is silent everywhere means
        /// missing data, not agreement — and a score measured without it is not a
        /// score of the design (BUILDLOG §4, suspect the instrument first).
        var spoke: [String: Int] = [:]
    }

    static func run(_ catalogURL: URL) throws -> Score {
        var s0 = Score()
        let c = try Catalog(url: catalogURL)

        let inputs = Pipeline.claims(c)   // exactly what the app resolves
        guard !inputs.isEmpty else { throw Err.empty }

        // Resolve from scratch rather than trusting the stored resolution, so the
        // back-test measures the current code and not a previous run's output.
        let (resolved, _) = Resolver.resolve(inputs)
        let ix = Resolver.index(inputs, resolved)

        // Only days the *file itself* dated AND zoned are ground truth. A day zoned
        // by inference is the ballot's own kind of guess, so scoring against it
        // would be marking its homework with its own answers.
        // A day whose own files disagree about their offset has no single right
        // answer, so it is excluded rather than scored against a coin toss.
        var tags: [Int: [Double: Int]] = [:]
        for r in resolved where r.zoneSource == "tag" && r.timeSource == "exif" {
            guard let d = Resolver.dayNumber(r.localTime), let o = r.utcOffset else { continue }
            tags[d, default: [:]][Resolver.offsetSeconds(o), default: 0] += 1
        }
        var truth: [Int: Double] = [:]
        for (day, offsets) in tags {
            if offsets.count > 1 { s0.contradictory += 1; continue }
            truth[day] = offsets.keys.first!
        }

        var s = s0
        for (day, actual) in truth.sorted(by: { $0.key < $1.key }) {
            guard let ctx = Resolver.context(day, ix, hiding: [day]) else { continue }
            let b = Ballot.rank(ctx)
            guard let best = b.ranked.first else { s.skipped += 1; continue }
            s.days += 1
            for name in best.perSignal.map(\.0) { s.spoke[name, default: 0] += 1 }
            let right = abs(best.offset - actual) < 60
            if !b.indistinguishable {
                s.committed += 1
                if right { s.committedRight += 1 }
            }
            if right {
                s.top += 1
                if b.indistinguishable { s.refusedButRight += 1 }
            } else {
                if !b.indistinguishable { s.confidentlyWrong += 1 }
                let hours = ((best.offset - actual) / 3600 * 4).rounded() / 4
                s.errors[hours, default: 0] += 1
            }
            if b.ranked.contains(where: { abs($0.offset - actual) < 60 }) { s.offered += 1 }
        }
        return s
    }

    enum Err: Error { case empty }

    /// The daylight signal ships with a shape nothing has validated. This tries a
    /// few and prints what each one actually scores on this collection, so the
    /// default is a measurement rather than a preference.
    static func sweepDaylight(_ catalogURL: URL) throws {
        let shapes: [(String, Double, Double)] = [
            ("off",              0,  0),
            ("peak ±4h (v1)",    0,  4),
            ("plateau 1 / 6",    1,  6),
            ("plateau 2 / 8",    2,  8),
            ("plateau 3 / 9",    3,  9),
            ("plateau 4 / 12",   4, 12),
            ("plateau 6 / 12",   6, 12),
        ]
        print("\ndaylight signal shape        top pick   offered   confidently wrong")
        for (name, plateau, cutoff) in shapes {
            Ballot.daylightPlateau = plateau
            Ballot.daylightCutoff = cutoff
            let s = try run(catalogURL)
            func pct(_ n: Int) -> String {
                s.days > 0 ? String(format: "%.1f%%", Double(n) * 100 / Double(s.days)) : "—"
            }
            print(String(format: "  %-26@ %8@  %8@  %8@", name as NSString,
                         pct(s.top) as NSString, pct(s.offered) as NSString,
                         pct(s.confidentlyWrong) as NSString))
        }
        Ballot.daylightPlateau = 4; Ballot.daylightCutoff = 12
    }

    static func report(_ s: Score) {
        func pct(_ n: Int) -> String {
            s.days > 0 ? String(format: "%.1f%%", Double(n) * 100 / Double(s.days)) : "—"
        }
        print("""

        timezone ballot, back-tested on days whose zone is known
          days scored          \(s.days)
          days excluded        \(s.contradictory)  (files on the day disagree)
          silent (no signal)   \(s.skipped)
          top pick right       \(s.top)  (\(pct(s.top)))
          right answer offered \(s.offered)  (\(pct(s.offered)))
          confidently wrong    \(s.confidentlyWrong)  (\(pct(s.confidentlyWrong)))
          right but refused    \(s.refusedButRight)  (\(pct(s.refusedButRight)))

          committed to an answer \(s.committed)  (\(pct(s.committed)) of days scored)
          …and was right         \(s.committedRight)  (\(s.committed > 0 ? String(format: "%.1f%%", Double(s.committedRight) * 100 / Double(s.committed)) : "—") of those)
        """)
        let names = ["Neighbouring day", "Time of day", "Daylight", "This camera", "Filename"]
        print("  signals that spoke: "
              + names.map { "\($0) \(pct(s.spoke[$0] ?? 0))" }.joined(separator: "  "))
        if !s.errors.isEmpty {
            let worst = s.errors.sorted { $0.value > $1.value }.prefix(6)
            print("  when wrong, by hours off: "
                  + worst.map { String(format: "%+.2fh ×%d", $0.key, $0.value) }.joined(separator: "  "))
        }
        // M6's gate, stated out loud rather than buried in a pass/fail.
        let committedPct = s.committed > 0 ? Double(s.committedRight) * 100 / Double(s.committed) : 0
        let offeredPct = s.days > 0 ? Double(s.offered) * 100 / Double(s.days) : 0
        print("  M6 gate: when it commits, right ≥95% — \(committedPct >= 95 ? "MET" : "NOT MET") "
              + "(\(String(format: "%.1f%%", committedPct)));  "
              + "truth among the three offered ≥95% — \(offeredPct >= 95 ? "MET" : "NOT MET") "
              + "(\(String(format: "%.1f%%", offeredPct)))")
    }
}
