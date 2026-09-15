// Making a Mac campaign openable on the iPad.
//
// The Mac build has The Butcher's Circus, the free player-versus-player add-on
// that never came to iOS. With it active the game records a "circus" building in
// the estate's Hamlet and lists the add-on among the ones it has shown the
// player. The iPad has no such building and crashes opening the campaign.
//
// This makes a copy with those two traces taken out, so what the iPad reads
// matches the shape it writes itself: the Hamlet without the Circus, and an
// empty list of presented add-ons. Everything else — every hero, every trinket,
// every scrap of progress — is copied through byte for byte.
//
// It is a copy. The Steam save keeps The Butcher's Circus and is never touched.

import Foundation

struct SanitiseReport {
    var profile: String
    var estate: String?
    var removed: [String] = []      // what came out, in words
    var leftAlone: [String] = []    // traces that stay, with the reason
    var changedFiles: [String] = []
    var clearedAddOnList = false
    var isClean: Bool { removed.isEmpty && leftAlone.isEmpty }
}

enum SanitiseFailure: Error, CustomStringConvertible {
    case rewriteUnverified(String)
    case stillIncompatible(String, String)
    var description: String {
        switch self {
        case .rewriteUnverified(let f):
            return "\(f) did not read back as the same save after the edit, so nothing was published"
        case .stillIncompatible(let marker, let f):
            return "\(f) still carries \(marker), which the iPad cannot load, so nothing was published"
        }
    }
}

enum Sanitise {
    /// Objects the iPad has no code for: the file they live in, the object to drop,
    /// and how to say what happened.
    static let removals: [(file: String, object: String, parent: String?, describe: String)] = [
        ("persist.town.json", "circus", "buildings",
         "the Butcher's Circus building in the Hamlet"),
        // Only the record of adverts shown. The campaign's own list of add-ons —
        // Crimson Court, Shieldbreaker, Colour of Madness, all of them sold for
        // the iPad too — is a different object of the same name and is left alone.
        ("persist.game.json", "dlc", "presented_dlc",
         "the note that the game once advertised the Butcher's Circus to you"),
    ]

    /// The campaign's own list of add-ons, under the save's root. The iPad writes
    /// no such list — its copy of this very campaign has none, Crimson Court
    /// heroes and all — so clearing it makes the copy match the shape the iPad
    /// produces. Optional, because it is a bigger change than taking out the
    /// Circus: it drops the record of which add-ons the campaign was started with.
    static let addOnList = (file: "persist.game.json", object: "dlc", parent: "base_root")

    /// Traces that cannot be lifted out without rewriting a value, and are left in.
    static let tolerated: [(file: String, marker: String, describe: String)] = [
        ("persist.narration.json", "arena",
         "two lines in the narration log remember an arena voice clip; they are a record of what has been said, not content the town has to load"),
    ]

    /// Writes a cleaned copy of `source` into `destination`. Files needing no
    /// change are copied unchanged. Throws without writing anything if a save
    /// file cannot be understood.
    @discardableResult
    static func copy(profile: String, from source: URL, to destination: URL, snapshot: Snapshot,
                     clearAddOnList: Bool = false) throws -> SanitiseReport {
        var report = SanitiseReport(profile: profile, estate: CampaignInfo.read(profileDir: source).estate)
        var rewritten: [String: Data] = [:]

        for rule in removals {
            guard snapshot.files[rule.file] != nil else { continue }
            let url = source.appendingPathComponent(rule.file)
            guard let data = try? Data(contentsOf: url) else { continue }
            guard var save = try? SaveFile(data) else {
                // One unreadable file does not stop the rest; whether that matters
                // is settled by the check below, before anything is written.
                report.leftAlone.append("\(rule.file) could not be read as a save file, so \(rule.describe) stays in")
                continue
            }
            guard save.removeObject(named: rule.object, under: rule.parent) else { continue }
            let out = save.serialized()
            // Refuse to write anything we cannot read back as the same thing.
            guard let check = try? SaveFile(out) else {
                throw SanitiseFailure.rewriteUnverified("\(rule.file): the rewritten bytes do not parse")
            }
            guard check.serialized() == out else {
                throw SanitiseFailure.rewriteUnverified("\(rule.file): rewriting it again gives different bytes (\(out.count) vs \(check.serialized().count))")
            }
            guard check.indexOfObject(named: rule.object, under: rule.parent) == nil else {
                throw SanitiseFailure.rewriteUnverified("\(rule.file): '\(rule.object)' is still there afterwards")
            }
            rewritten[rule.file] = out
            report.removed.append(rule.describe)
            report.changedFiles.append(rule.file)
        }

        if clearAddOnList, snapshot.files[addOnList.file] != nil {
            let url = source.appendingPathComponent(addOnList.file)
            if let data = try? rewritten[addOnList.file] ?? Data(contentsOf: url), var save = try? SaveFile(data),
               save.removeObject(named: addOnList.object, under: addOnList.parent) {
                let out = save.serialized()
                guard let check = try? SaveFile(out), check.serialized() == out,
                      check.indexOfObject(named: addOnList.object, under: addOnList.parent) == nil else {
                    throw SanitiseFailure.rewriteUnverified("\(addOnList.file): clearing the add-on list did not read back cleanly")
                }
                rewritten[addOnList.file] = out
                report.clearedAddOnList = true
                report.removed.append("the campaign's list of add-ons, which the iPad does not write either")
                if !report.changedFiles.contains(addOnList.file) { report.changedFiles.append(addOnList.file) }
            }
        }

        // Nothing is published until the copy is free of everything known to crash
        // the iPad. Better no copy than one that crashes on open.
        for issue in Compatibility.iPadCannotLoad {
            for file in issue.files {
                guard snapshot.files[file] != nil else { continue }
                let data = try rewritten[file] ?? Data(contentsOf: source.appendingPathComponent(file))
                if Compatibility.bytesContain(data, issue.marker) {
                    throw SanitiseFailure.stillIncompatible(issue.marker, file)
                }
            }
        }

        for t in tolerated {
            guard let data = try? Data(contentsOf: source.appendingPathComponent(t.file)),
                  let save = try? SaveFile(data), save.mentions(t.marker) else { continue }
            report.leftAlone.append(t.describe)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in snapshot.files.keys.sorted() {
            let data = try rewritten[name] ?? Data(contentsOf: source.appendingPathComponent(name))
            try data.write(to: destination.appendingPathComponent(name))
        }
        if let extra = try? fm.contentsOfDirectory(atPath: destination.path) {
            for name in extra where !Snapshot.ignored(name) && snapshot.files[name] == nil {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: destination.appendingPathComponent(name).path, isDirectory: &isDir), !isDir.boolValue {
                    try? fm.removeItem(at: destination.appendingPathComponent(name))
                }
            }
        }
        return report
    }
}
