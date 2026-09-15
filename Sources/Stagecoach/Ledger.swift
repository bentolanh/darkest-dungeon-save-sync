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
}

struct Ledger: Codable, Equatable {
    var profiles: [String: ProfileRecord] = [:]
    var processedExports: [String] = []          // export folders already consumed
    var conflicts: [Conflict] = []
    var resolutions: [String: String] = [:]      // conflict id → "mac" | "ipad"

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
