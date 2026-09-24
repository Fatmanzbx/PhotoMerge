import Foundation

/// Tidy in place: move the extra copies to the Trash, where they can be put back.
///
/// Three rules, each a way this could otherwise destroy a photograph:
///  1. Nothing inside a Photos library package (`*.photoslibrary`) is touched.
///     Moving a file out of `originals/` corrupts the library that owns it.
///  2. A duplicate is trashed only if its *kept* copy still exists and still has
///     the content the grouping saw — the last copy of a photograph is never moved.
///  3. A duplicate is trashed only if it is itself unchanged since it was read.
/// Every move is recorded, so it can be restored, file by file or all at once.
enum Tidy {

    struct Candidate: Equatable {
        let fileID: Int, path: String, sha: String?
        let keptPath: String, keptSha: String?
        let bytes: Int
    }

    struct Plan: Equatable {
        var candidates: [Candidate] = []
        var inPhotosLibrary = 0          // refused: rule 1
        var bytes: Int { candidates.reduce(0) { $0 + $1.bytes } }
    }

    static func isInsidePhotosLibrary(_ path: String) -> Bool {
        path.lowercased().contains(".photoslibrary/")
    }

    static func plan(_ c: Catalog) -> Plan {
        var p = Plan()
        if let st = try? c.prepare("""
            SELECT d.file_id, fd.path, fd.sha256, fk.path, fk.sha256, fd.size
            FROM member d JOIN file fd ON fd.id = d.file_id
            JOIN member k ON k.cluster_id = d.cluster_id AND k.role = 'canonical'
            JOIN file fk ON fk.id = k.file_id
            WHERE d.role = 'duplicate'
              AND d.file_id NOT IN (SELECT t.file_id FROM trashed t WHERE t.original = fd.path)
            ORDER BY fd.path;
            """) {
            while st.step() {
                let path = st.text(1) ?? ""
                if isInsidePhotosLibrary(path) { p.inPhotosLibrary += 1; continue }
                p.candidates.append(Candidate(fileID: st.int(0), path: path, sha: st.text(2),
                                              keptPath: st.text(3) ?? "", keptSha: st.text(4), bytes: st.int(5)))
            }
            st.finalize()
        }
        return p
    }

    struct Report: Equatable { var moved = 0, skipped = 0, bytes = 0; var reasons: [String] = [] }

    /// The Trash a file on that volume goes to.
    static func systemTrash(_ u: URL) -> URL? {
        try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: u, create: false)
    }

    /// `trash` moves a file and returns where it went — the system Trash by
    /// default; tests pass a folder of their own (and `trashFolder` naming it) so
    /// they never touch the real one.
    static func run(_ c: Catalog,
                    trash: (URL) throws -> URL = { u in
                        var out: NSURL?
                        try FileManager.default.trashItem(at: u, resultingItemURL: &out)
                        return (out as URL?) ?? u
                    },
                    trashFolder: (URL) -> URL? = systemTrash,
                    progress: (Int, Int) -> Void = { _, _ in }) -> Report {
        reconcile(c, trashFolder: trashFolder)
        var r = Report()
        let candidates = plan(c).candidates
        var keptHash: [String: String?] = [:]      // a kept copy is checked once, not once per duplicate
        for (n, cand) in candidates.enumerated() {
            progress(n, candidates.count)
            func skip(_ why: String) { r.skipped += 1; r.reasons.append("\((cand.path as NSString).lastPathComponent): \(why)") }
            let kept = keptHash[cand.keptPath] ?? { let h = Extractor.shaOfFile(cand.keptPath); keptHash[cand.keptPath] = h; return h }()
            guard let kept, kept == cand.keptSha else { skip("its kept copy is missing or has changed"); continue }
            guard let own = Extractor.shaOfFile(cand.path) else { skip("it is already gone"); continue }
            guard own == cand.sha else { skip("it has changed since it was read"); continue }
            // Recorded before the move, with where it went left blank until known: a
            // crash in between must not leave a file in the Trash that Restore forgot.
            func note(_ trashPath: String) {
                try? c.transaction {
                    let st = try c.prepare("INSERT OR REPLACE INTO trashed(file_id, sha, original, trash_path, at) VALUES(?,?,?,?,?);")
                    st.bind(1, cand.fileID).bind(2, cand.sha).bind(3, cand.path).bind(4, trashPath)
                      .bind(5, Date().timeIntervalSince1970).done(); st.finalize()
                }
            }
            note("")
            do {
                let dest = try trash(URL(fileURLWithPath: cand.path))
                Crash.point("tidy.moved")
                note(dest.path)
                r.moved += 1; r.bytes += cand.bytes
            } catch { forget(c, cand.fileID); skip("could not be moved: \(error.localizedDescription)") }
        }
        return r
    }

    struct RestoreReport: Equatable { var restored = 0, missing = 0, occupied = 0 }

    /// Put trashed copies back where they were — never over a file that has since
    /// taken the name. `only` restores just those files.
    static func restore(_ c: Catalog, only: Set<Int>? = nil, trashFolder: (URL) -> URL? = systemTrash) -> RestoreReport {
        reconcile(c, trashFolder: trashFolder)
        var r = RestoreReport()
        var rows: [(Int, String, String)] = []
        if let st = try? c.prepare("SELECT file_id, original, trash_path FROM trashed ORDER BY at DESC;") {
            while st.step() { rows.append((st.int(0), st.text(1) ?? "", st.text(2) ?? "")) }
            st.finalize()
        }
        let fm = FileManager.default
        for (id, original, inTrash) in rows where only?.contains(id) ?? true {
            if fm.fileExists(atPath: original) { r.occupied += 1; continue }
            guard fm.fileExists(atPath: inTrash) else { r.missing += 1; forget(c, id); continue }
            do {
                try fm.createDirectory(atPath: (original as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try fm.moveItem(atPath: inTrash, toPath: original)
                forget(c, id); r.restored += 1
            } catch { r.missing += 1 }
        }
        return r
    }

    /// Settle rows a crash left without a Trash location: if the file never left,
    /// drop the row; if it did, find it in the Trash by its size and hash.
    static func reconcile(_ c: Catalog, trashFolder: (URL) -> URL?) {
        var rows: [(Int, String, String?, Int)] = []
        if let st = try? c.prepare("""
            SELECT t.file_id, t.original, t.sha, COALESCE(f.size, -1) FROM trashed t
            LEFT JOIN file f ON f.id = t.file_id WHERE t.trash_path = '';
            """) {
            while st.step() { rows.append((st.int(0), st.text(1) ?? "", st.text(2), st.int(3))) }
            st.finalize()
        }
        let fm = FileManager.default
        for (id, original, sha, size) in rows {
            if fm.fileExists(atPath: original) { forget(c, id); continue }
            guard let folder = trashFolder(URL(fileURLWithPath: original)),
                  let names = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }
            let found = names.lazy.map { folder.appendingPathComponent($0).path }.first { p in
                ((try? fm.attributesOfItem(atPath: p)[.size] as? Int) ?? -2) == size
                    && Extractor.shaOfFile(p) == sha
            }
            guard let found else { continue }      // stays pending; Restore reports it missing
            try? c.transaction { let st = try c.prepare("UPDATE trashed SET trash_path = ? WHERE file_id = ?;")
                                 st.bind(1, found).bind(2, id).done(); st.finalize() }
        }
    }

    private static func forget(_ c: Catalog, _ id: Int) {
        try? c.transaction { let st = try c.prepare("DELETE FROM trashed WHERE file_id = ?;")
                             st.bind(1, id).done(); st.finalize() }
    }
}
