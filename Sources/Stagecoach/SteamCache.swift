// Reads Steam's own bookkeeping for the game's cloud files (remotecache.vdf):
// what the client believes the cloud holds, and what it still has work to do
// about. Read-only; the client owns this file.
//
// It is the cheap way to ask what is in Steam Cloud. The alternative is opening
// a Steamworks session, which makes the account show as playing the game, so it
// is not something to do on a timer.

import Foundation

enum SteamCache {
    struct Entry: Equatable {
        var name: String            // "profile_1/persist.game.json"
        var syncState: String       // "1" = agreed with the cloud; anything else = outstanding
        var persistState: String    // "2" = deleted here, and the cloud not yet told

        var isPending: Bool { syncState != "1" }
        var isDeletedLocally: Bool { persistState == "2" }
    }

    /// Every file the client holds a record of.
    static func entries(in cache: URL) -> [Entry] {
        guard let text = try? String(contentsOf: cache, encoding: .utf8) else { return [] }
        var out: [Entry] = []
        var name: String?
        var sync = "", persist = ""
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let parts = line.split(separator: "\"").map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if parts.count == 1, parts[0].contains("/") || parts[0].hasSuffix(".json") {
                // A block named for a file. The outer block is the app id, which
                // has neither a slash nor a .json, so it never starts one.
                name = parts[0]; sync = ""; persist = ""
            } else if parts.count == 2, name != nil {
                if parts[0] == "syncstate" { sync = parts[1] }
                if parts[0] == "persiststate" { persist = parts[1] }
            } else if line == "}", let n = name {
                out.append(Entry(name: n, syncState: sync, persistState: persist))
                name = nil
            }
        }
        return out
    }

    /// Names (like "profile_1/persist.game.json") whose syncstate isn't 1 (synced).
    static func pendingFiles(in cache: URL) -> [String] {
        entries(in: cache).filter(\.isPending).map(\.name)
    }

    /// The profile folders the client has cloud records for: profile_0, profile_4…
    static func cloudProfiles(in cache: URL) -> Set<String> {
        var out: Set<String> = []
        for e in entries(in: cache) {
            guard let slot = e.name.split(separator: "/").first.map(String.init),
                  slot.hasPrefix("profile_"), Int(slot.dropFirst("profile_".count)) != nil else { continue }
            out.insert(slot)
        }
        return out
    }
}
