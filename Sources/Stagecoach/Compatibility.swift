// Not every Mac save can be opened on the iPad. The Mac build has The Butcher's
// Circus, a free PvP add-on that never came to iOS. When it is active the game
// writes a "circus" building into the estate's town data and arena entries into
// the campaign and narration files. The iPad has no code for that building, so
// loading such a campaign crashes it — Red Hook's own import article warns that
// saves carrying content the iPad lacks "may result in errors".
//
// This is about content, not about the copy: the bytes reach Dropbox intact.
// So before a Mac save is published for the iPad to import, it is checked for
// markers of content the iPad cannot load, and held back if any are found.

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
         "The Butcher's Circus building is in this estate's Hamlet. The iPad has no Butcher's Circus, so loading the campaign crashes it."),
        ("arena_mp", ["persist.game.json"],
         "The campaign records Butcher's Circus arena play, which the iPad does not know."),
    ]

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
