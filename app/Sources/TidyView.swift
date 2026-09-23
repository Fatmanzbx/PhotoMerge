import SwiftUI

/// Tidy in place: the extra copies to the Trash, restorable.
struct TidyView: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        let p = engine.tidyPlan
        Card {
            VStack(alignment: .leading, spacing: D.Space.m) {
                if p.candidates.isEmpty && p.inPhotosLibrary == 0 {
                    Label(engine.tidied > 0 ? "All extra copies are in the Trash." : "There are no extra copies to move.",
                          systemImage: "checkmark.circle.fill").foregroundStyle(D.keep)
                } else if !p.candidates.isEmpty {
                    Text("\(p.candidates.count) extra cop\(p.candidates.count == 1 ? "y" : "ies") · \(byteString(p.bytes))")
                        .font(.system(size: 26, weight: .semibold))
                    Text("Each goes to the Trash only if the copy being kept is still there and unchanged — the last copy of a photo is never moved. You can put them back from here, with ⌘Z, or from the Trash itself.")
                        .font(.system(size: 18)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button { engine.tidy() } label: {
                        Label("Move \(p.candidates.count) to the Trash", systemImage: "trash")
                    }
                    .buttonStyle(.bigProminent).controlSize(.extraLarge)
                    .disabled(engine.progress.running)
                }
                if p.inPhotosLibrary > 0 {
                    Label {
                        Text("\(p.inPhotosLibrary) extra cop\(p.inPhotosLibrary == 1 ? "y is" : "ies are") inside your Photos library and cannot be tidied from here — moving files out of a Photos library damages it. Delete them in Photos, or save a clean library instead.")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(D.attention) }
                    .font(.system(size: 18))
                }
                if engine.tidied > 0 {
                    Divider()
                    HStack {
                        Text("\(engine.tidied) moved to the Trash so far").font(.system(size: 18)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Put them all back") { engine.putBack() }.disabled(engine.progress.running)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
