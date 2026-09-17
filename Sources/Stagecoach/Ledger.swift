// The ledger remembers what the two sides last agreed on, so the app can tell
// "the Mac has played since" from "nothing changed" and never ping-pongs a
// save back and forth. It lives in Application Support as plain JSON.

import Foundation

struct ProfileRecord: Codable, Equatable {
    var syncedDigest: String        // digest both sides held after the last sync
    var syncedSaveTime: Date?       // when the Mac's newest save file was written, at that sync
    var syncedAt: Date
    var lastSource: String          // "mac" or "ipad"
    var cloudState: String          // "uploaded" | "pendingGameLaunch" | "n/a"
}

struct Conflict: Codable, Equatable, Identifiable {
    var id: String { "\(exportFolder)/\(sourceProfile ?? profile)" }
    var profile: String            // the Steam slot
    var exportFolder: String
    var estate: String?
    var macNewest: Date?
    var ipadNewest: Date?
    var detectedAt: Date
    var sourceProfile: String?     // the slot inside the export folder
    var firstMeeting = false       // never synced before, rather than both having moved
}

/// A campaign Steam Cloud still holds that this Mac no longer has on disk.
///
/// Deleting a slot with the Finder only takes the local copy: the client keeps
/// its own, and puts it back — or argues about it — at the next launch. Either
/// the slot was meant to go, in which case the cloud should be told, or it was
/// not, in which case it can be fetched back. Both are the person's call, so
/// this is only ever raised, never acted on.
struct Orphan: Codable, Equatable, Identifiable {
    var id: String { profile }
    var profile: String
    var files: Int
    var noticedAt: Date
}

struct Ledger: Codable, Equatable {
    var profiles: [String: ProfileRecord] = [:]
    var processedExports: [String] = []          // export folders already consumed
    var conflicts: [Conflict] = []
    var resolutions: [String: String] = [:]      // conflict id → "mac" | "ipad"
    /// Slots whose published copy was cleaned for the iPad, and the Mac digest it
    /// was made from. Kept across restarts so a prepared copy is not re-flagged.
    var publishedFrom: [String: String] = [:]
    /// Campaigns in Steam Cloud with no folder on this Mac, and what was decided
    /// about them: "forget" removes the cloud copy, "keep" leaves it alone and
    /// stops the asking.
    var orphans: [Orphan] = []
    var orphanChoices: [String: String] = [:]

    static let url = Paths.supportDir.appendingPathComponent("ledger.json")

    static func load(from url: URL = Ledger.url) -> Ledger {
        guard let data = try? Data(contentsOf: url) else { return Ledger() }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        return (try? dec.decode(Ledger.self, from: data)) ?? Ledger()
    }

    func save(to url: URL = Ledger.url) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
