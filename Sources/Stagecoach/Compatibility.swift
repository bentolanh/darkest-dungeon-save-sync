// Whether a Mac campaign can be opened on the iPad.
//
// Much less stands in the way than this file once claimed. Tested on 2026-09-16
// by taking one campaign the iPad had written, copying it twice on the Mac, and
// switching add-ons on in the game: one copy got every add-on except The
// Butcher's Circus, the other got all of them. Both were carried back untouched
// and both opened on an iPad that has none of those add-ons. The game warns that
// it will remove the add-on content and cannot undo it, and then gets on with it.
//
// So three things once believed here are wrong. Add-ons can be switched on for a
// campaign that already exists — only switching one off is impossible. A
// campaign asking for add-ons the iPad has not got still opens. And The
// Butcher's Circus is not fatal either.
//
// What remains unexplained is one campaign: the Sal estate built and played on
// this Mac, which crashes the iPad on load while campaigns that began on the
// iPad come back fine. Fifteen of its sixteen files were written by the Mac
// build, against four in a campaign that works, so the difference is likely to
// be in one of the eleven files no test has yet carried across in Mac-written
// form. Until that is known, nothing is held back on a guess: a campaign is
// published with a note about what it will warn about, and the iPad decides.

import Foundation

struct CompatibilityIssue: Equatable {
    var marker: String      // what was found
    var file: String        // which save file it was found in
    var explanation: String
}

enum Compatibility {
    /// Markers of PC-only content, by the file they live in. Matched as raw bytes
    /// so the binary save format needs no decoding.
    static let iPadCannotLoad: [(marker: String, files: [String], explanation: String)] = [
        ("circus", ["persist.town.json"],
         "The Butcher's Circus building is in this estate's Hamlet, and the iPad has no Butcher's Circus. Switching the add-on on for a campaign turned out to be harmless, but no campaign with the building itself has been carried over yet, so this one waits."),
        // Not arena_mp: it sits in the list of add-ons the game has shown the
        // player, and a campaign carrying it was opened on the iPad without
        // complaint on 2026-09-16. Only the building itself is a problem.
    ]

    /// The add-ons a campaign cannot do without, that the iPad has not got.
    /// `iPadHas` is read from a save the iPad wrote; with none to read, nothing
    /// is claimed and the check stays quiet.
    static func missingAddOns(profileDir: URL, iPadHas: Set<String>?) -> [String] {
        guard let iPadHas, !iPadHas.isEmpty else { return [] }
        let needs = Set(Sanitise.addOns(in: profileDir.appendingPathComponent("persist.game.json")))
        guard !needs.isEmpty else { return [] }
        return needs.subtracting(iPadHas).sorted()
    }

    /// How an add-on is spelled for a person to read.
    static func readable(_ addOn: String) -> String {
        switch addOn {
        case "crimson_court": return "The Crimson Court"
        case "color_of_madness": return "The Color of Madness"
        case "shieldbreaker": return "The Shieldbreaker"
        case "musketeer": return "The Musketeer"
        case "districts": return "Districts"
        case "flagellant": return "The Flagellant"
        default: return addOn
        }
    }

    /// What in this profile folder would stop the iPad loading it.
    static func check(profileDir: URL) -> [CompatibilityIssue] {
        var found: [CompatibilityIssue] = []
        for entry in iPadCannotLoad {
            for file in entry.files {
                guard let data = try? Data(contentsOf: profileDir.appendingPathComponent(file)) else { continue }
                if contains(data, Array(entry.marker.utf8)) {
                    found.append(CompatibilityIssue(marker: entry.marker, file: file, explanation: entry.explanation))
                    break
                }
            }
        }
        return found
    }

    static func bytesContain(_ data: Data, _ marker: String) -> Bool {
        contains(data, Array(marker.utf8))
    }

    /// What an estate's purse carries that belongs to an add-on. Used to notice
    /// when a save coming back from the iPad has had its add-on content stripped.
    static func addOnBelongings(profileDir: URL) -> Set<String> {
        guard let d = try? Data(contentsOf: profileDir.appendingPathComponent("persist.estate.json")) else { return [] }
        var found: Set<String> = []
        for name in ["shard", "memory", "blueprint", "martyrs_seal"] where bytesContain(d, name) {
            found.insert(name)
        }
        return found
    }

    private static func contains(_ haystack: Data, _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        let bytes = [UInt8](haystack)
        let last = bytes.count - needle.count
        var i = 0
        while i <= last {
            if bytes[i] == needle[0], Array(bytes[i..<i + needle.count]) == needle { return true }
            i += 1
        }
        return false
    }
}
