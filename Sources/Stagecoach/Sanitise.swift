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
    var matchedIPadBuild = false
    var strippedNewer: [String: Int] = [:]   // field name → how many were taken out
    var isClean: Bool { removed.isEmpty && leftAlone.isEmpty }
}

enum SanitiseFailure: Error, CustomStringConvertible {
    case inconsistent(String, String)
    case rewriteUnverified(String)
    case stillIncompatible(String, String)
    var description: String {
        switch self {
        case .inconsistent(let f, let why):
            return "\(f) did not hold together after the edit (\(why)), so nothing was published"
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

    /// The build the iPad's own saves are written by. Its last content update was
    /// 2019 and its last release 2022; Steam is thousands of builds ahead.
    static let iPadBuild = 24774

    /// Structures the newer build writes that the iPad's build never does.
    ///
    /// Each line was checked against two saves the iPad wrote itself: the field
    /// appears in the Steam save and appears nowhere in either iPad save, in that
    /// file. The file matters. `hero_name` is a newer addition inside the estate,
    /// the quest and the town, but the iPad has always written it in the campaign
    /// log — a hundred times over — so taking it out everywhere would throw away
    /// the campaign's own history. `heroes` likewise is the iPad's own word in
    /// three files and is left alone in all of them.
    static let newerThanIPad: [(file: String, field: String, describe: String)] = [
        ("persist.estate.json", "tampering", "the newer build's save-tampering record"),
        ("persist.estate.json", "foundLocalTamperedFile", "a save-tampering flag"),
        ("persist.estate.json", "foundGlobalTamperedFile", "a save-tampering flag"),
        ("persist.campaign_log.json", "trinket_feedback_data", "trinket feedback the newer build logs"),
        ("novelty_tracker.json", "banner", "a banner the newer build tracks"),
        ("persist.town_event.json", "heirloom_gain_multiplier", "a newer town-event value"),
        ("persist.town_event.json", "nomad_wagon_trinket_discount", "a newer town-event value"),
        ("persist.town_event.json", "nomad_wagon_trinket_discount_available", "a newer town-event value"),
    ] + ["persist.estate.json", "persist.quest.json", "persist.town.json"].flatMap { file in
        // The newer build added these to every hero record in these three files.
        ["added_buffs", "did_transform", "hero_name", "previous_trinket_id", "trinkets_gained_count"]
            .map { (file: file, field: $0, describe: "a field the newer build added to each hero in \(file)") }
    }

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
                     clearAddOnList: Bool = false, matchIPadBuild: Bool = false) throws -> SanitiseReport {
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

        if matchIPadBuild {
            // Every save file in the campaign gets the iPad's build stamp, and the
            // structures that build never wrote are taken out of the files that
            // carry them.
            var perFile: [String: [(String, String)]] = [:]
            for entry in newerThanIPad { perFile[entry.file, default: []].append((entry.field, entry.describe)) }

            for name in snapshot.files.keys.sorted() where name.hasSuffix(".json") {
                let data = try rewritten[name] ?? Data(contentsOf: source.appendingPathComponent(name))
                guard var save = try? SaveFile(data) else {
                    report.leftAlone.append("\(name) could not be read as a save file, so it keeps its original build stamp")
                    continue
                }
                var touched = save.build != iPadBuild
                save.build = iPadBuild

                for (field, _) in perFile[name] ?? [] {
                    let n = save.removeAll(named: field)
                    if n > 0 { report.strippedNewer[field, default: 0] += n; touched = true }
                }
                guard touched else { continue }

                let out = save.serialized()
                guard let check = try? SaveFile(out), check.serialized() == out, check.build == iPadBuild else {
                    throw SanitiseFailure.rewriteUnverified("\(name): matching the iPad's build did not read back cleanly")
                }
                rewritten[name] = out
                if !report.changedFiles.contains(name) { report.changedFiles.append(name) }
            }
            report.matchedIPadBuild = true
            report.removed.append("everything stamped as build \(iPadBuild), the one the iPad writes, instead of \(SaveFile.steamBuildHint)")
            for (f, n) in report.strippedNewer.sorted(by: { $0.key < $1.key }) {
                let what = (newerThanIPad.first { $0.field == f }?.describe) ?? "a structure the newer build added"
                report.removed.append("\(what) — \(f), \(n) place\(n == 1 ? "" : "s")")
            }
        }

        // Every file that was touched has to hold together as a save in its own
        // right. Round-tripping alone would not catch a number written back
        // exactly as it was read but wrong for the tree it now describes.
        for (name, bytes) in rewritten.sorted(by: { $0.key < $1.key }) {
            guard let save = try? SaveFile(bytes) else {
                throw SanitiseFailure.inconsistent(name, "it no longer reads as a save")
            }
            if let first = save.inconsistencies().first {
                throw SanitiseFailure.inconsistent(name, first)
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
