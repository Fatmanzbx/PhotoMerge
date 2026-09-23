import SwiftUI
import AppKit

/// Write a clean, merged copy: one file per photograph, dated and placed, in a
/// folder you choose. The summary is computed before anything is written, so the
/// consequences are visible first (PLAN §3: understand, then act).
struct WriteView: View {
    @EnvironmentObject var engine: Engine
    @State private var confirmUndo = false

    var body: some View {
        if engine.stats.assets == 0 {
            EmptyState(icon: "square.and.arrow.down.on.square", title: "Nothing to write yet",
                       message: "Analyse a folder first. The merged copy is built from what the analysis found.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: D.Space.l) {
                    intro
                    destination
                    if let s = engine.actSummary { summary(s) }
                    options
                    actions
                    if let r = engine.actReport, !r.failures.isEmpty { failures(r) }
                }
                .padding(20)
                .frame(maxWidth: 1150, alignment: .leading)
            }
            .onAppear { engine.loadAct() }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: D.Space.xs) {
            Text("A merged copy of your library")
                .font(.system(size: 28, weight: .semibold))
            Text("One file per photograph — the best copy, with every duplicate left out — named by when it was taken, with the dates, timezones and places worked out here written into it. Your originals are never modified: this is a new folder, and every file in it is read back and checked against its original before it counts as written.")
                .font(.system(size: 18)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var destination: some View {
        Card {
            HStack(spacing: D.Space.m) {
                Image(systemName: "folder.badge.plus").font(.system(size: 22)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.outputRoot.map { ($0 as NSString).lastPathComponent } ?? "No destination chosen")
                        .font(.system(size: 22, weight: .medium))
                    if let r = engine.outputRoot {
                        Text(r).font(.system(size: 15)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                    if let e = engine.actError {
                        Text(e).font(.system(size: 15)).foregroundStyle(D.attention)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Button(engine.outputRoot == nil ? "Choose…" : "Change…") { engine.chooseDestination() }
                    .disabled(engine.progress.running)
            }
        }
    }

    private func summary(_ s: Act.Summary) -> some View {
        VStack(alignment: .leading, spacing: D.Space.s) {
            SectionLabel(text: "What will be written")
            Card {
                VStack(alignment: .leading, spacing: D.Space.m) {
                    HStack(spacing: 22) {
                        Metric(value: "\(s.photographs)", label: "photographs")
                        Metric(value: "\(s.clips)", label: "live clips")
                        Metric(value: "\(engine.stats.duplicates)", label: "duplicates left out",
                               tint: engine.stats.duplicates > 0 ? D.keep : nil)
                        Metric(value: byteString(s.bytes), label: "to write")
                        if engine.writtenCount > 0 {
                            Metric(value: "\(engine.writtenCount)", label: "already written", tint: D.keep,
                                   fraction: s.files > 0 ? Double(engine.writtenCount) / Double(s.files) : nil)
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        line("calendar", "\(s.datesFilled) photographs gain a capture date they had only outside the file",
                             show: s.datesFilled > 0)
                        line("location", "\(s.placesRead) gain a place from their Takeout sidecar", show: s.placesRead > 0)
                        line("location.fill.viewfinder", "\(s.placesWorkedOut) gain a place estimated from other photographs",
                             show: s.placesWorkedOut > 0, inferred: true)
                        line("globe", "\(s.zonesWorkedOut) gain a time zone estimated from other photographs",
                             show: s.zonesWorkedOut > 0, inferred: true)
                        line("questionmark.folder", "\(s.undated) go to Undated/ under their own names — no date to go by",
                             show: s.undated > 0)
                        line("clock.badge.questionmark", "\(s.inUTC) are named in UTC (…Z) — their instant is exact, their zone unknown",
                             show: s.inUTC > 0)
                        line("checkmark.seal", "every date field is written, so no reader finds a stale one", show: true)
                    }
                    if !s.sample.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("First files, as they will be named").font(.system(size: 15).weight(.medium)).foregroundStyle(.secondary)
                            ForEach(s.sample, id: \.self) {
                                Text($0).font(.system(size: 20, design: .monospaced)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func line(_ icon: String, _ text: String, show: Bool, inferred: Bool = false) -> some View {
        if show {
            Label {
                Text(text).font(.system(size: 18))
            } icon: {
                Image(systemName: icon).foregroundStyle(inferred ? AnyShapeStyle(D.attention) : AnyShapeStyle(.secondary))
            }
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: D.Space.s) {
            SectionLabel(text: "What to write")
            Card {
                VStack(alignment: .leading, spacing: D.Space.s) {
                    Toggle(isOn: Binding(get: { engine.actOptions.writePlaces },
                                         set: { var o = engine.actOptions; o.writePlaces = $0; engine.setActOptions(o) })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Write places estimated from other photographs")
                            Text("Places read from a file or its sidecar are always written. A file's own GPS is never replaced.")
                                .font(.system(size: 15)).foregroundStyle(.secondary)
                        }
                    }
                    Toggle(isOn: Binding(get: { engine.actOptions.writeInferredZones },
                                         set: { var o = engine.actOptions; o.writeInferredZones = $0; engine.setActOptions(o) })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Write time zones estimated from other photographs")
                            Text("Timezones read from the file, derived exactly, or chosen by you are always written.")
                                .font(.system(size: 15)).foregroundStyle(.secondary)
                        }
                    }
                }
                .toggleStyle(.switch)
                .disabled(engine.progress.running)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: D.Space.m) {
            Button {
                engine.startWrite()
            } label: {
                Label(engine.writtenCount > 0 ? "Continue writing" : "Write merged copy",
                      systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bigProminent).controlSize(.extraLarge)
            .disabled(engine.outputRoot == nil || engine.actError != nil || engine.progress.running)

            if let r = engine.outputRoot, engine.writtenCount > 0 {
                Button("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: r)) }
                Spacer()
                if confirmUndo {
                    Text("Remove the \(engine.writtenCount) written files?").font(.system(size: 18))
                    Button("Remove", role: .destructive) { confirmUndo = false; engine.undoWrite() }
                    Button("Keep") { confirmUndo = false }
                } else {
                    Button("Undo…") { confirmUndo = true }
                        .help("Removes the files this wrote — only those still exactly as written. Your originals are not involved.")
                        .disabled(engine.progress.running)
                }
            }
        }
    }

    private func failures(_ r: Act.Report) -> some View {
        VStack(alignment: .leading, spacing: D.Space.s) {
            SectionLabel(text: "Not written — \(r.failed)")
            Card {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(r.failures.prefix(20).enumerated()), id: \.offset) { _, f in
                        HStack(alignment: .firstTextBaseline) {
                            Text((f.0 as NSString).lastPathComponent).font(.system(size: 20, weight: .medium))
                            Text(f.1).font(.system(size: 20)).foregroundStyle(.secondary)
                        }
                    }
                    Text("Nothing half-written was left behind. Continuing tries these again.")
                        .font(.system(size: 15)).foregroundStyle(.tertiary)
                }
            }
        }
    }
}
