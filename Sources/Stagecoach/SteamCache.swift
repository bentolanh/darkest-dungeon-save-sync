// Reads Steam's own bookkeeping for the game's cloud files (remotecache.vdf):
// which files it still considers pending upload. Read-only; the client owns it.

import Foundation

enum SteamCache {
    /// Names (like "profile_1/persist.game.json") whose syncstate isn't 1 (synced).
    static func pendingFiles(in cache: URL) -> [String] {
        guard let text = try? String(contentsOf: cache, encoding: .utf8) else { return [] }
        var pending: [String] = []
        var current: String?
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let parts = line.split(separator: "\"").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if parts.count == 1, parts[0].contains("/") || parts[0].hasSuffix(".json") {
                current = parts[0]
            } else if parts.count == 2, parts[0] == "syncstate", let name = current {
                if parts[1] != "1" { pending.append(name) }
                current = nil
            } else if line == "}" {
                current = nil
            }
        }
        return pending
    }
}
