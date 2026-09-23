import Foundation

/// The guided path: Add photos → Duplicates → Time & place → Save. Duplicates and
/// Time & place can be taken in either order and revisited; Save opens once every
/// photograph has a date and a place, or the person has chosen to leave the rest.
/// The cards below summarise what needs attention, as a testable model; the
/// advanced panes remain for those who want them.
enum Guide {

    enum Step: Int, CaseIterable, Identifiable {
        case add, duplicates, places, save
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .add: return "Add photos"; case .duplicates: return "Duplicates"
            case .places: return "Time & place"; case .save: return "Save"
            }
        }
    }

    struct Inputs: Equatable {
        var duplicates = 0, wastedBytes = 0
        var editedCopies = 0
        var wrongZones = 0, wrongZoneDays = 0
        var unclearDays = 0
        var missingDate = 0, missingPlace = 0, missingEither = 0
        var unreadable = 0
        var unavailableSources = 0
    }

    struct Card: Identifiable, Equatable {
        enum Kind: String { case wrongTime, duplicates, edited, unclearDay, missing, unreadable, unavailable }
        let kind: Kind
        let title: String
        let detail: String
        let action: String            // the one obvious button
        let secondary: String?        // "Show me", "Leave them"…
        /// Changes whenever the underlying items change, so a card acknowledged
        /// once returns when something new needs attention.
        let signature: String
        var id: String { kind.rawValue }
    }

    static func cards(_ i: Inputs) -> [Card] {
        func s(_ n: Int, _ one: String, _ many: String) -> String { "\(n.formatted()) \(n == 1 ? one : many)" }
        var out: [Card] = []
        if i.unavailableSources > 0 {
            out.append(Card(kind: .unavailable, title: s(i.unavailableSources, "folder can't be found", "folders can't be found"),
                            detail: "An unplugged drive, or a folder that moved. Nothing from it is forgotten; plug it back in and analyse again.",
                            action: "OK", secondary: nil, signature: "\(i.unavailableSources)"))
        }
        if i.wrongZones > 0 {
            out.append(Card(kind: .wrongTime, title: s(i.wrongZones, "photo shows the wrong time", "photos show the wrong time"),
                            detail: "Their time zone contradicts where and when they were taken"
                                + (i.wrongZoneDays > 0 ? " — \(i.wrongZoneDays) of them land on the wrong day" : "")
                                + ". Correcting keeps the moment they were taken and fixes the clock.",
                            action: "Correct all", secondary: "Show me", signature: "\(i.wrongZones)"))
        }
        if i.duplicates > 0 {
            out.append(Card(kind: .duplicates, title: s(i.duplicates, "duplicate copy found", "duplicate copies found"),
                            detail: "The best copy of each photo is kept. The extra copies take \(byteString(i.wastedBytes)).",
                            action: "Looks right", secondary: "Show me", signature: "\(i.duplicates):\(i.wastedBytes)"))
        }
        if i.editedCopies > 0 {
            out.append(Card(kind: .edited, title: s(i.editedCopies, "edited copy", "edited copies"),
                            detail: "The same shot, but cropped, filtered or brightened. Keep both, or treat them as one photo? Your call — nothing is merged without you.",
                            action: "Decide…", secondary: "Keep them all", signature: "\(i.editedCopies)"))
        }
        if i.unclearDays > 0 {
            out.append(Card(kind: .unclearDay, title: s(i.unclearDays, "day's time zone is unclear", "days' time zones are unclear"),
                            detail: "Photos from these days record a clock but not where in the world it was. The app suggests the likeliest zones; you choose.",
                            action: "Decide…", secondary: "Leave them", signature: "\(i.unclearDays)"))
        }
        if i.missingEither > 0 {
            let parts = [i.missingDate > 0 ? s(i.missingDate, "without a date", "without a date") : nil,
                         i.missingPlace > 0 ? s(i.missingPlace, "without a place", "without a place") : nil]
                .compactMap { $0 }.joined(separator: ", ")
            out.append(Card(kind: .missing, title: s(i.missingEither, "photo is missing a date or place", "photos are missing a date or place"),
                            detail: "\(parts). Nothing inside them says, and nothing nearby could fill it in. Add the day and place yourself, many at once — or leave them.",
                            action: "Fill in…", secondary: "Leave them", signature: "\(i.missingEither)"))
        }
        if i.unreadable > 0 {
            out.append(Card(kind: .unreadable, title: s(i.unreadable, "file couldn't be opened", "files couldn't be opened"),
                            detail: "Usually a permissions problem, or a file that was being written. It is tried again if it changes.",
                            action: "OK", secondary: nil, signature: "\(i.unreadable)"))
        }
        return out
    }
}
