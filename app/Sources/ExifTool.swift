import Foundation

/// A persistent exiftool process. Bundled, not linked: exiftool is Perl under
/// GPL/Artistic, so it ships as a separate executable run as a subprocess (SPIKES §1).
/// `-stay_open` keeps one Perl interpreter alive across thousands of files — the
/// per-invocation start-up is otherwise most of the cost.
///
/// One instance per writer thread; each call is serialised on its own lock.
final class ExifTool {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var buffer = Data()

    enum Err: Error { case notFound, died, failed(String) }

    /// The bundled copy, else one the developer points at, else Homebrew's.
    static func locate() -> URL? {
        var candidates: [String] = []
        if let r = Bundle.main.resourceURL?.appendingPathComponent("exiftool/exiftool").path { candidates.append(r) }
        if let e = ProcessInfo.processInfo.environment["PM_EXIFTOOL"] { candidates.append(e) }
        candidates += ["/opt/homebrew/bin/exiftool", "/usr/local/bin/exiftool"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0)
                                  || FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    init() throws {
        guard let tool = ExifTool.locate() else { throw Err.notFound }
        // Run through the system Perl explicitly: the script's own shebang names a
        // Homebrew perl that a user's machine will not have.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [tool.path, "-stay_open", "True", "-@", "-"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
    }

    deinit {
        if process.isRunning {
            try? input.fileHandleForWriting.write(contentsOf: Data("-stay_open\nFalse\n".utf8))
            process.waitUntilExit()
        }
    }

    /// Run one command; returns exiftool's combined output for it.
    @discardableResult
    func run(_ args: [String]) throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard process.isRunning else { throw Err.died }
        // one argument per line: filenames with spaces need no quoting this way
        let cmd = args.map { $0.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\n")
            + "\n-execute\n"
        try input.fileHandleForWriting.write(contentsOf: Data(cmd.utf8))
        let marker = Data("{ready}".utf8)
        while true {
            if let r = buffer.range(of: marker) {
                let out = String(decoding: buffer[..<r.lowerBound], as: UTF8.self)
                var end = r.upperBound
                while end < buffer.endIndex, buffer[end] == 0x0A || buffer[end] == 0x0D { end += 1 }
                buffer.removeSubrange(..<end)
                return out.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { throw Err.died }
            buffer.append(chunk)
        }
    }

    /// Write tags to a file in place. Refuses to report success on exiftool's
    /// "0 image files updated", which is how its silent failures look (BUILDLOG §2.4).
    func write(_ path: String, _ tags: [String: String], extra: [String] = []) throws {
        guard !tags.isEmpty else { return }
        // No -q: besides quieting messages it suppresses the `{ready}` marker the
        // stay-open protocol depends on, and the reader then waits forever.
        let args = ["-overwrite_original", "-m"] + extra
            + tags.sorted { $0.key < $1.key }.map { "-\($0.key)=\($0.value)" } + [path]
        let out = try run(args)
        // Success is exiftool saying so, not the absence of an error.
        guard out.contains("1 image files updated") else { throw Err.failed(out) }
    }

    /// Read tags back, as `Group:Tag → value`, for verification. JSON output, so
    /// the group and the tag name are never confused with the value.
    func read(_ path: String, _ tags: [String]) throws -> [String: String] {
        let out = try run(["-j", "-G1", "-n"] + tags.map { "-" + $0 } + [path])
        guard let start = out.firstIndex(of: "["),
              let arr = try? JSONSerialization.jsonObject(with: Data(out[start...].utf8)) as? [[String: Any]],
              let obj = arr.first else { return [:] }
        var r: [String: String] = [:]
        for (k, v) in obj where k != "SourceFile" { r[k] = "\(v)" }
        return r
    }

    var version: String? { (try? run(["-ver"])).flatMap { $0.isEmpty ? nil : $0 } }
}
