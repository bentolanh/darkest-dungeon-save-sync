// Two edits make a Mac campaign open on the iPad. Everything else this file
// once did turned out to be unnecessary, and most of it was wrong.
//
// The iPad runs a build of the game from 2019. The Mac's is thousands of builds
// newer, and the difference that matters is small:
//
//   1. Each chapter of the campaign log holds numbered entries, one per thing
//      worth recording about that week. The newer build writes an extra entry
//      carrying `trinket_feedback_data`. The older build has never written one
//      and refuses the campaign. Removing the field alone does not help — the
//      entry stays behind holding only its type marker — so the entry goes
//      whole and its siblings are renumbered.
//
//   2. The record of which add-ons the game has shown the player names the
//      Butcher's Circus, which never came to iOS. Taking that one entry out
//      stops the iPad asking about add-ons it cannot provide.
//
// Found on 2026-09-16 by two experiments neither of which was mine. Playing one
// week on a campaign the iPad had written produced a save that broke from a
// single known action; playing the same week on the iPad produced the chapter
// to compare it against. Against those, everything inferred from unrelated
// campaigns had been aimed at the wrong files.
//
// What is deliberately NOT done, each having been tested and found unnecessary:
// removing the Butcher's Circus building from the Hamlet, the add-on currencies
// and trinkets in the estate, the quests and narration mentioning add-on
// content, the per-hero fields the newer build adds, the upgrade trees the iPad
// does not know, and restamping each file with the iPad's build number. A
// campaign carrying all of those opened on the iPad once these two edits were
// made. A campaign is also never held back for needing add-ons the iPad has not
// got: the game offers to remove that content itself, and does.

import Foundation

enum SanitiseFailure: Error, CustomStringConvertible {
    case inconsistent(String, String)

    var description: String {
        switch self {
        case .inconsistent(let file, let why):
            return "\(file) did not hold together after the edit (\(why)), so nothing was published"
        }
    }
}

struct SanitiseReport {
    var estate: String?
    var removed: [String] = []
    var changedFiles: [String] = []
}

enum Sanitise {
    /// The record the newer build adds to a chapter of the campaign log.
    static let newerChapterRecord = "trinket_feedback_data"

    /// The add-on that never came to iOS, as it is named in the save.
    static let circusAddOn = "arena_mp"

    /// Removes each numbered chapter entry carrying this record, whole, and
    /// renumbers the entries left beside it so they still run from zero.
    @discardableResult
    static func removeChapterEntries(_ save: inout SaveFile, carrying marker: String) -> Int {
        var removed = 0
        while true {
            guard let leaf = save.fields.firstIndex(where: { $0.name == marker }),
                  let entry = save.owner(of: leaf) else { break }
            let entryField = save.objects[entry].nameField
            guard let chapter = save.owner(of: entryField) else { break }
            save.removeObject(at: entryField)
            removed += 1
            let siblings = save.childObjects(ofObject: chapter)
                .filter { Int(save.fields[$0].name) != nil }
                .sorted { (Int(save.fields[$0].name) ?? 0) < (Int(save.fields[$1].name) ?? 0) }
            for (i, sibling) in siblings.enumerated() { save.renameField(at: sibling, to: String(i)) }
        }
        return removed
    }

    /// Removes one add-on from a named list, renumbering what is left.
    @discardableResult
    static func removeAddOn(_ save: inout SaveFile, named wanted: String, from list: String) -> Bool {
        guard let dlc = save.indexOfObject(named: "dlc", under: list) else { return false }
        let entries = save.childObjects(ofObject: save.fields[dlc].object)
        guard let doomed = entries.first(where: { entry in
            let object = save.fields[entry].object
            let start = save.objects[object].nameField
            let end = min(start + 1 + save.objects[object].all, save.fields.count)
            return (start..<end).contains { save.fields[$0].name == "name" && save.stringValue(at: $0) == wanted }
        }) else { return false }
        save.removeObject(at: doomed)
        for (i, entry) in save.childObjects(ofObject: save.fields[dlc].object).enumerated() {
            save.renameField(at: entry, to: String(i))
        }
        return true
    }

    /// Which add-ons a campaign says it uses, or has been shown.
    static func addOns(in gameFile: URL, under parent: String = "base_root") -> [String] {
        guard let data = try? Data(contentsOf: gameFile), let save = try? SaveFile(data) else { return [] }
        return addOns(in: save, under: parent)
    }

    static func addOns(in save: SaveFile, under parent: String) -> [String] {
        guard let dlc = save.indexOfObject(named: "dlc", under: parent) else { return [] }
        return save.childObjects(ofObject: save.fields[dlc].object).compactMap { entry in
            let object = save.fields[entry].object
            let start = save.objects[object].nameField
            let end = min(start + 1 + save.objects[object].all, save.fields.count)
            return (start..<end).first { save.fields[$0].name == "name" }.flatMap { save.stringValue(at: $0) }
        }
    }

    /// Publishes a copy of a campaign for the iPad: the two edits, an optional
    /// rename so several copies of one campaign can be told apart, and every
    /// other file carried across byte for byte.
    @discardableResult
    static func copy(profile: String, from source: URL, to destination: URL, snapshot: Snapshot,
                     rename: String? = nil) throws -> SanitiseReport {
        var report = SanitiseReport(estate: CampaignInfo.read(profileDir: source).estate)
        var rewritten: [String: Data] = [:]

        if snapshot.files["persist.campaign_log.json"] != nil {
            let url = source.appendingPathComponent("persist.campaign_log.json")
            if let data = try? Data(contentsOf: url), var save = try? SaveFile(data) {
                let n = removeChapterEntries(&save, carrying: newerChapterRecord)
                if n > 0 {
                    rewritten["persist.campaign_log.json"] = save.serialized()
                    report.removed.append("\(n) chapter entr\(n == 1 ? "y" : "ies") of a kind the iPad's build never wrote")
                }
            }
        }

        if snapshot.files["persist.game.json"] != nil {
            let url = source.appendingPathComponent("persist.game.json")
            if let data = try? Data(contentsOf: url), var save = try? SaveFile(data) {
                var touched = false
                if removeAddOn(&save, named: circusAddOn, from: "presented_dlc") {
                    report.removed.append("the Butcher's Circus from the record of add-ons the game has shown you")
                    touched = true
                }
                if let rename, let i = save.fields.firstIndex(where: { $0.name == "estatename" }) {
                    save.setStringValue(at: i, to: rename)
                    report.removed.append("the estate renamed to \(rename) so it can be told apart")
                    report.estate = rename
                    touched = true
                }
                if touched { rewritten["persist.game.json"] = save.serialized() }
            }
        }

        // Every rewritten file must still be a save in its own right. Reading the
        // same bytes back is not enough: three separate faults here — a flag in
        // the top bit of a field's info word, the four-byte footing of a value,
        // and the hash stored beside a name — all survived that and were only
        // caught by rebuilding what the file claims and comparing.
        for (name, bytes) in rewritten.sorted(by: { $0.key < $1.key }) {
            guard let save = try? SaveFile(bytes), save.serialized() == bytes else {
                throw SanitiseFailure.inconsistent(name, "it no longer reads back as the same save")
            }
            if let first = save.inconsistencies().first {
                throw SanitiseFailure.inconsistent(name, first)
            }
        }

        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in snapshot.files.keys.sorted() {
            let bytes = try rewritten[name] ?? Data(contentsOf: source.appendingPathComponent(name))
            let target = destination.appendingPathComponent(name)
            if let existing = try? Data(contentsOf: target), existing == bytes { continue }
            try bytes.write(to: target)
        }
        report.changedFiles = rewritten.keys.sorted()
        return report
    }
}
