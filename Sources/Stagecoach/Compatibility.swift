// Whether a Mac campaign can be opened on the iPad.
//
// Almost nothing stands in the way, which took a long time to establish. The
// add-ons a campaign uses can be switched on after it is created, and a campaign
// asking for add-ons the iPad has not got still opens there — the game offers to
// remove that content and does. A Hamlet with a Butcher's Circus building in it
// opens too. All of that was tested on 2026-09-16 and none of it is a reason to
// hold a campaign back.
//
// So nothing is held back. What is left here is the one thing worth saying out
// loud: which add-ons a campaign will lose on the way over, so that is not a
// surprise.

import Foundation

enum Compatibility {
    /// The add-ons a campaign cannot do without, that the iPad has not got.
    /// `iPadHas` is read from a campaign the iPad wrote; with none to read,
    /// nothing is claimed.
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
        case "arena_mp": return "The Butcher's Circus"
        default: return addOn
        }
    }

    /// What an estate's purse and trinket case carry that belongs to an add-on.
    /// Used to notice when a campaign coming back from the iPad has had its
    /// add-on content stripped, which the game offers to do and cannot undo.
    static func addOnBelongings(profileDir: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: profileDir.appendingPathComponent("persist.estate.json")) else { return [] }
        return Set(["shard", "memory", "blueprint"].filter { bytesContain(data, $0) })
    }

    /// True when these raw bytes appear anywhere in the file.
    static func bytesContain(_ data: Data, _ marker: String) -> Bool {
        let needle = Array(marker.utf8)
        let hay = [UInt8](data)
        guard hay.count >= needle.count, !needle.isEmpty else { return false }
        for i in 0...(hay.count - needle.count) where Array(hay[i..<i + needle.count]) == needle { return true }
        return false
    }
}
