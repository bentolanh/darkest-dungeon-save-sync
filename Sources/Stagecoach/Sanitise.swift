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
    ]

    /// The campaign's own list of add-ons, under the save's root. The iPad writes
    /// no such list — its copy of this very campaign has none, Crimson Court
    /// heroes and all — so clearing it makes the copy match the shape the iPad
    /// produces. Optional, because it is a bigger change than taking out the
    /// Circus: it drops the record of which add-ons the campaign was started with.
    static let addOnList = (file: "persist.game.json", object: "dlc", parent: "base_root")

    /// What the iPad stamps into each file, read from a save it wrote itself.
    ///
    /// The stamp is not the game's build. It is the build in which that file's
    /// format last changed, and it differs from file to file: the iPad writes
    /// 24774 into most, 21980 into the curio tracker and the tutorial, 20343
    /// into what the game knows. The Mac agrees on the tutorial and disagrees on
    /// the rest. Stamping one number across a whole campaign tells the iPad that
    /// three of its files are in a format they are not in.
    static func buildStamps(reference: URL) -> [String: Int] {
        var out: [String: Int] = [:]
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: reference.path) else { return out }
        for name in names where name.hasSuffix(".json") && !Snapshot.ignored(name) {
            if let d = try? Data(contentsOf: reference.appendingPathComponent(name)),
               let save = try? SaveFile(d) {
                out[name] = save.build
            }
        }
        return out
    }

    /// The build the iPad's own saves are written by. Its last content update was
    /// 2019 and its last release 2022; Steam is thousands of builds ahead.
    static let iPadBuild = 24774

    // Nothing below is done unless it is asked for. Every one of these removals
    // was written while the iPad was believed to need it, and the iPad turned out
    // to handle its own add-on content perfectly well. Left on by default, they
    // tore four quests out of a campaign that legitimately had those add-ons
    // switched on, and the Mac itself then refused to open it.

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

    /// The sanitarium records a trinket against each quirk. Neither iPad save has
    /// ever recorded a quirk at all, so there is no evidence about whether its
    /// build knows the field — which is why this is asked for rather than assumed.
    static let quirkTrinket = (file: "persist.town.json", field: "trinketId")

    /// The add-ons a campaign says it uses live in a `dlc` object at the save's
    /// root, one numbered entry each. The iPad shows its activation window for
    /// anything listed there that it does not have, and a campaign asking for an
    /// add-on the iPad cannot provide is one it cannot open. Trimming the list to
    /// what a save from the iPad itself asks for is what stops that.
    static func addOns(in gameFile: URL, under parent: String = "base_root") -> [String] {
        guard let d = try? Data(contentsOf: gameFile), let s = try? SaveFile(d) else { return [] }
        return addOns(in: s, under: parent)
    }

    static func addOns(in s: SaveFile, under parent: String) -> [String] {
        guard let dlc = s.indexOfObject(named: "dlc", under: parent) else { return [] }
        var out: [String] = []
        for entry in s.childObjects(ofObject: s.fields[dlc].object) {
            if let n = s.fields.indices.first(where: { $0 > entry && s.fields[$0].name == "name" }),
               let v = s.stringValue(at: n) { out.append(v) }
        }
        return out
    }

    /// Keeps only the named add-ons in the campaign's list, renumbering what is
    /// left so the entries still run from zero.
    static func trimAddOns(_ save: inout SaveFile, under parent: String, keeping allowed: Set<String>) -> [String] {
        guard let dlc = save.indexOfObject(named: "dlc", under: parent) else { return [] }
        var dropped: [String] = []
        while true {
            let entries = save.childObjects(ofObject: save.fields[dlc].object)
            var removedOne = false
            for entry in entries {
                guard let n = save.fields.indices.first(where: { $0 > entry && save.fields[$0].name == "name" }),
                      let name = save.stringValue(at: n) else { continue }
                if !allowed.contains(name) {
                    dropped.append(name)
                    save.removeObject(at: entry)
                    removedOne = true
                    break
                }
            }
            if !removedOne { break }
        }
        for (i, entry) in save.childObjects(ofObject: save.fields[dlc].object).enumerated() {
            save.renameField(at: entry, to: String(i))
        }
        return dropped
    }

    /// Which add-ons the iPad has switched on. Its Activate DLC screen lists all
    /// six — Musketeer, Crimson Court, Districts, Flagellant, Shieldbreaker,
    /// Colour of Madness — so every name is one it knows. What matters is not
    /// whether it knows the name but whether the add-on is enabled there: a
    /// campaign asking for one that is off cannot be opened, and the import
    /// screen reads every campaign in the folder, so one such campaign takes the
    /// whole screen down with it rather than just itself.
    ///
    /// The answer is read from a save the iPad wrote rather than assumed. On this
    /// Mac that comes to Musketeer and Shieldbreaker.
    static func addOnsEnabledOnTheIPad(reference: URL) -> Set<String>? {
        let list = addOns(in: reference.appendingPathComponent("persist.game.json"))
        return list.isEmpty ? nil : Set(list)
    }

    /// The list of add-ons the game has shown the player keeps everything the
    /// iPad's own screen offers. Only the Butcher's Circus, which that screen has
    /// never listed, comes out.
    static let shownAddOnsToKeep: Set<String> =
        ["musketeer", "crimson_court", "districts", "flagellant", "shieldbreaker", "color_of_madness"]

    /// Content belonging to an add-on the iPad has switched off. A campaign
    /// carrying any of it is one the iPad says it cannot open without stripping
    /// the add-ons out for good: an offered quest from Colour of Madness, a
    /// Crimson Court item promised as its reward, a line of narration about the
    /// Butcher's Circus arena. The numbered entries holding them come out whole,
    /// and what remains is renumbered.
    static let switchedOffContent: [(file: String, list: String, markers: [String], describe: String)] = [
        ("persist.quest.json", "quests",
         ["cc_", "crimson", "courtyard", "color_of_madness", "farmstead", "comet"],
         "quests offering add-on content the iPad has switched off"),
        ("persist.narration.json", "town_visit_entry_log",
         ["arena"],
         "lines in the town narration log about the Butcher's Circus arena"),
        ("persist.narration.json", "campaign_entry_log",
         ["arena"],
         "lines in the campaign narration log about the Butcher's Circus arena"),
        ("persist.narration.json", "raid_entry_log",
         ["arena"],
         "lines in the raid narration log about the Butcher's Circus arena"),
    ]

    /// The estate's purse carries a line per currency. Gold, busts, portraits,
    /// deeds and crests are the game's own; shards and memories come with Colour
    /// of Madness and blueprints with Districts, and an estate holding one of
    /// those is an estate the iPad says it cannot open without stripping the
    /// add-ons out for good. The line is matched on the currency itself rather
    /// than on any mention of the word, so nothing else can be caught by it.
    static let switchedOffCurrencies: Set<String> = ["shard", "memory", "blueprint"]

    /// Trinkets that come with an add-on. Their names give nothing away — a
    /// Martyr's Seal is Crimson Court but says so nowhere — so this is a list of
    /// what has actually been met, not a rule that can be derived from the file.
    /// It is therefore certainly incomplete, and the game's own offer to strip
    /// add-on content remains the only exhaustive answer.
    static let switchedOffTrinkets: Set<String> = ["martyrs_seal"]

    /// The building upgrades a campaign has bought, each recorded against a tree
    /// identified by a four-byte number rather than a name. The Mac build knows
    /// trees the iPad has never heard of — after one week of play on 2026-09-16 a
    /// campaign that had only trees the iPad knows had gained seventeen it does
    /// not, across a hundred and one purchases, and it stopped loading there.
    /// Every campaign that crashes has some; every campaign that loads has none.
    ///
    /// Which trees are which cannot be worked out from the file, so the answer is
    /// taken from a campaign the iPad wrote: any purchase against a tree that
    /// appears in no such campaign comes out.
    static func upgradeTrees(in profileDir: URL) -> Set<[UInt8]> {
        guard let d = try? Data(contentsOf: profileDir.appendingPathComponent("persist.upgrades.json")),
              let s = try? SaveFile(d) else { return [] }
        return Set(s.fields.filter { $0.name == "tree_id" }.map { Array($0.value.prefix(4)) })
    }

    /// Removes every purchase made against a tree outside the given set, and
    /// renumbers what remains.
    static func trimUpgrades(_ save: inout SaveFile, keeping known: Set<[UInt8]>) -> Int {
        guard let list = save.indexOfObject(named: "purchases") else { return 0 }
        var removed = 0
        while true {
            let entries = save.childObjects(ofObject: save.fields[list].object)
            var doomed: Int? = nil
            for entry in entries {
                let o = save.fields[entry].object
                let start = save.objects[o].nameField
                let end = min(start + 1 + save.objects[o].all, save.fields.count)
                for i in start..<end where save.fields[i].name == "tree_id" {
                    if !known.contains(Array(save.fields[i].value.prefix(4))) { doomed = entry }
                    break
                }
                if doomed != nil { break }
            }
            guard let entry = doomed else { break }
            save.removeObject(at: entry)
            removed += 1
        }
        if removed > 0 {
            for (i, entry) in save.childObjects(ofObject: save.fields[list].object).enumerated() {
                save.renameField(at: entry, to: String(i))
            }
        }
        return removed
    }

    /// Removes numbered entries under a list by the value of one of their fields,
    /// renumbering what remains.
    static func removeEntries(_ save: inout SaveFile, under list: String, inside parent: String? = nil,
                              whereField field: String, isOneOf unwanted: Set<String>) -> [String] {
        // "items" is a name many lists use, so the enclosing object has to be
        // named too when it matters — the estate's trinkets live in trinkets/items.
        guard let listField = save.indexOfObject(named: list, under: parent) else { return [] }
        var dropped: [String] = []
        while true {
            let entries = save.childObjects(ofObject: save.fields[listField].object)
            var hit: (Int, String)? = nil
            for entry in entries {
                let o = save.fields[entry].object
                let start = save.objects[o].nameField
                let end = min(start + 1 + save.objects[o].all, save.fields.count)
                for i in start..<end where save.fields[i].name == field {
                    if let v = save.stringValue(at: i), unwanted.contains(v) { hit = (entry, v) }
                    break
                }
                if hit != nil { break }
            }
            guard let (entry, name) = hit else { break }
            save.removeObject(at: entry)
            dropped.append(name)
        }
        if !dropped.isEmpty {
            for (i, entry) in save.childObjects(ofObject: save.fields[listField].object).enumerated() {
                save.renameField(at: entry, to: String(i))
            }
        }
        return dropped
    }

    /// Removes the numbered entries under a list whose contents mention any of
    /// these, renumbering the rest so they still run from zero.
    static func removeEntriesMentioning(_ save: inout SaveFile, under list: String, markers: [String]) -> Int {
        guard let listField = save.indexOfObject(named: list) else { return 0 }
        var removed = 0
        while true {
            let entries = save.childObjects(ofObject: save.fields[listField].object)
            guard let doomed = entries.first(where: { entry in
                let o = save.fields[entry].object
                return markers.contains { save.subtree(ofObject: o, mentions: $0) }
            }) else { break }
            save.removeObject(at: doomed)
            removed += 1
        }
        if removed > 0 {
            for (i, entry) in save.childObjects(ofObject: save.fields[listField].object).enumerated() {
                save.renameField(at: entry, to: String(i))
            }
        }
        return removed
    }

    /// Fields the newer build writes inside a hero's own record. Every hero on
    /// this Mac carries a trinketId; no hero the iPad wrote has ever had one.
    static let newerInsideHeroes = ["trinketId", "added_buffs", "did_transform",
                                    "hero_name", "previous_trinket_id", "trinkets_gained_count"]

    /// Opens each hero in the roster and takes those fields out of it.
    static func cleanHeroes(_ save: inout SaveFile) -> (heroes: Int, removed: Int) {
        var touched = 0, removed = 0
        for i in save.fields.indices where save.fields[i].name == "raw_data" {
            guard var hero = save.embeddedSave(at: i) else { continue }
            var n = 0
            for field in newerInsideHeroes { n += hero.removeAll(named: field) }
            guard n > 0 else { continue }
            guard hero.inconsistencies().isEmpty else { continue }
            save.setEmbeddedSave(at: i, to: hero)
            touched += 1; removed += n
        }
        return (touched, removed)
    }

    /// Traces that cannot be lifted out without rewriting a value, and are left in.
    static let tolerated: [(file: String, marker: String, describe: String)] = [
    ]

    /// Writes a cleaned copy of `source` into `destination`. Files needing no
    /// change are copied unchanged. Throws without writing anything if a save
    /// file cannot be understood.
    @discardableResult
    static func copy(profile: String, from source: URL, to destination: URL, snapshot: Snapshot,
                     clearAddOnList: Bool = false, matchIPadBuild: Bool = false,
                     stripNewerStructures: Bool = false, stripCircus: Bool = false,
                     stripNewerIn: Set<String>? = nil, knownUpgradeTrees: Set<[UInt8]>? = nil,
                     stripQuirkTrinkets: Bool = false,
                     keepAddOns: Set<String>? = nil, rename: String? = nil,
                     buildStamps: [String: Int] = [:]) throws -> SanitiseReport {
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

        if matchIPadBuild || stripNewerStructures || stripNewerIn != nil {
            // Every save file in the campaign gets the iPad's build stamp, and the
            // structures that build never wrote are taken out of the files that
            // carry them.
            var perFile: [String: [(String, String)]] = [:]
            for entry in newerThanIPad { perFile[entry.file, default: []].append((entry.field, entry.describe)) }

            for name in snapshot.files.keys.sorted() where name.hasSuffix(".json")
                && (stripNewerIn == nil || stripNewerIn!.contains(name)) {
                let data = try rewritten[name] ?? Data(contentsOf: source.appendingPathComponent(name))
                guard var save = try? SaveFile(data) else {
                    report.leftAlone.append("\(name) could not be read as a save file, so it keeps its original build stamp")
                    continue
                }
                var touched = false
                // Per file: what a save from the iPad carries for this very file,
                // falling back to the one the iPad writes for most of them.
                let want = buildStamps[name] ?? iPadBuild
                if matchIPadBuild, save.build != want { save.build = want; touched = true }

                for (field, _) in ((stripNewerStructures || stripNewerIn != nil) ? (perFile[name] ?? []) : []) {
                    let n = save.removeAll(named: field)
                    if n > 0 { report.strippedNewer[field, default: 0] += n; touched = true }
                }
                guard touched else { continue }

                let out = save.serialized()
                guard let check = try? SaveFile(out), check.serialized() == out,
                      !matchIPadBuild || check.build == want else {
                    throw SanitiseFailure.rewriteUnverified("\(name): matching the iPad's build did not read back cleanly")
                }
                rewritten[name] = out
                if !report.changedFiles.contains(name) { report.changedFiles.append(name) }
            }
            if matchIPadBuild {
                report.matchedIPadBuild = true
                report.removed.append("each file stamped with the build the iPad writes for that file")
            }
            for (f, n) in report.strippedNewer.sorted(by: { $0.key < $1.key }) {
                let what = (newerThanIPad.first { $0.field == f }?.describe) ?? "a structure the newer build added"
                report.removed.append("\(what) — \(f), \(n) place\(n == 1 ? "" : "s")")
            }
        }

        if stripNewerStructures, snapshot.files["persist.estate.json"] != nil {
            let url = source.appendingPathComponent("persist.estate.json")
            if let data = try? rewritten["persist.estate.json"] ?? Data(contentsOf: url),
               var save = try? SaveFile(data) {
                var dropped = removeEntries(&save, under: "wallet", whereField: "type", isOneOf: switchedOffCurrencies)
                let trinkets = removeEntries(&save, under: "items", inside: "trinkets",
                                             whereField: "id", isOneOf: switchedOffTrinkets)
                dropped += trinkets
                if !dropped.isEmpty {
                    let out = save.serialized()
                    guard let check = try? SaveFile(out), check.serialized() == out, check.inconsistencies().isEmpty else {
                        throw SanitiseFailure.inconsistent("persist.estate.json", "removing the add-on currencies left it unsound")
                    }
                    rewritten["persist.estate.json"] = out
                    report.removed.append("add-on belongings in the estate — \(dropped.joined(separator: ", "))")
                    if !report.changedFiles.contains("persist.estate.json") { report.changedFiles.append("persist.estate.json") }
                }
            }
        }

        // The novelty tracker notes each trinket the player has seen, by name, as
        // the field itself rather than as a value in a list.
        if stripNewerStructures, snapshot.files["novelty_tracker.json"] != nil {
            let url = source.appendingPathComponent("novelty_tracker.json")
            if let data = try? rewritten["novelty_tracker.json"] ?? Data(contentsOf: url),
               var save = try? SaveFile(data) {
                var gone: [String] = []
                for trinket in switchedOffTrinkets.sorted() where save.removeAll(named: trinket) > 0 {
                    gone.append(trinket)
                }
                if !gone.isEmpty {
                    let out = save.serialized()
                    guard let check = try? SaveFile(out), check.serialized() == out, check.inconsistencies().isEmpty else {
                        throw SanitiseFailure.inconsistent("novelty_tracker.json", "removing an add-on trinket left it unsound")
                    }
                    rewritten["novelty_tracker.json"] = out
                    report.removed.append("add-on trinkets noted as seen — \(gone.joined(separator: ", "))")
                    if !report.changedFiles.contains("novelty_tracker.json") { report.changedFiles.append("novelty_tracker.json") }
                }
            }
        }

        if let known = knownUpgradeTrees, !known.isEmpty, snapshot.files["persist.upgrades.json"] != nil {
            let url = source.appendingPathComponent("persist.upgrades.json")
            if let data = try? rewritten["persist.upgrades.json"] ?? Data(contentsOf: url),
               var save = try? SaveFile(data) {
                let n = trimUpgrades(&save, keeping: known)
                if n > 0 {
                    let out = save.serialized()
                    guard let check = try? SaveFile(out), check.serialized() == out, check.inconsistencies().isEmpty else {
                        throw SanitiseFailure.inconsistent("persist.upgrades.json", "removing unknown upgrade trees left it unsound")
                    }
                    rewritten["persist.upgrades.json"] = out
                    report.removed.append("\(n) building upgrades bought in trees the iPad has never recorded")
                    if !report.changedFiles.contains("persist.upgrades.json") { report.changedFiles.append("persist.upgrades.json") }
                }
            }
        }

        for rule in switchedOffContent where stripNewerStructures {
            guard snapshot.files[rule.file] != nil else { continue }
            let url = source.appendingPathComponent(rule.file)
            guard let data = try? rewritten[rule.file] ?? Data(contentsOf: url),
                  var save = try? SaveFile(data) else { continue }
            let n = removeEntriesMentioning(&save, under: rule.list, markers: rule.markers)
            guard n > 0 else { continue }
            let out = save.serialized()
            guard let check = try? SaveFile(out), check.serialized() == out, check.inconsistencies().isEmpty else {
                throw SanitiseFailure.inconsistent(rule.file, "removing \(rule.describe) left it unsound")
            }
            rewritten[rule.file] = out
            report.removed.append("\(n) \(rule.describe)")
            if !report.changedFiles.contains(rule.file) { report.changedFiles.append(rule.file) }
        }

        if stripNewerStructures || (stripNewerIn?.contains("persist.roster.json") ?? false),
           snapshot.files["persist.roster.json"] != nil {
            let url = source.appendingPathComponent("persist.roster.json")
            if let data = try? rewritten["persist.roster.json"] ?? Data(contentsOf: url),
               var save = try? SaveFile(data) {
                let (heroes, fields) = cleanHeroes(&save)
                if heroes > 0 {
                    rewritten["persist.roster.json"] = save.serialized()
                    report.removed.append("\(fields) fields the newer build added inside \(heroes) hero records")
                    if !report.changedFiles.contains("persist.roster.json") { report.changedFiles.append("persist.roster.json") }
                }
            }
        }

        if snapshot.files["persist.game.json"] != nil {
            let url = source.appendingPathComponent("persist.game.json")
            if let data = try? rewritten["persist.game.json"] ?? Data(contentsOf: url), var save = try? SaveFile(data) {
                if let allowed = keepAddOns {
                    let dropped = trimAddOns(&save, under: "base_root", keeping: allowed)
                    if !dropped.isEmpty {
                        report.removed.append("the add-ons this campaign asked for that the iPad does not have — \(dropped.joined(separator: ", "))")
                    }
                }
                // The record of which add-ons the game has shown the player is what
                // tells it the save has already been reconciled with them. Emptying
                // it makes the game ask again and refuse. Only the Butcher's Circus
                // comes out; the rest of the list stays exactly as it is.
                let shownDropped = trimAddOns(&save, under: "presented_dlc", keeping: shownAddOnsToKeep)
                if !shownDropped.isEmpty {
                    report.removed.append("the Butcher's Circus from the list of add-ons the game has shown you — \(shownDropped.joined(separator: ", "))")
                }
                if let rename, let i = save.fields.firstIndex(where: { $0.name == "estatename" }) {
                    save.setStringValue(at: i, to: rename)
                    report.removed.append("the estate renamed to \(rename) so it can be told apart")
                }
                rewritten["persist.game.json"] = save.serialized()
                if !report.changedFiles.contains("persist.game.json") { report.changedFiles.append("persist.game.json") }
            }
        }

        if stripQuirkTrinkets, snapshot.files[quirkTrinket.file] != nil {
            let url = source.appendingPathComponent(quirkTrinket.file)
            if let data = try? rewritten[quirkTrinket.file] ?? Data(contentsOf: url), var save = try? SaveFile(data) {
                let n = save.removeAll(named: quirkTrinket.field)
                if n > 0 {
                    rewritten[quirkTrinket.file] = save.serialized()
                    report.removed.append("the trinket recorded against each quirk in the sanitarium — \(quirkTrinket.field), \(n) places")
                    if !report.changedFiles.contains(quirkTrinket.file) { report.changedFiles.append(quirkTrinket.file) }
                }
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
