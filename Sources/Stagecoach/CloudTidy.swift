// Removing a campaign from Steam Cloud.
//
// Deleting the folder on disk is not enough on its own. The client keeps its
// own copy and settles the difference at the next launch, either by putting the
// slot back or by stopping to ask which side is right. Telling the cloud is a
// separate errand, and it needs the client running.
//
// The copy is taken before anything is deleted, and the delete is abandoned if
// it fails: once a slot is gone from disk, the cloud's copy may be the last one.

import Foundation

enum CloudTidy {
    struct Result: Equatable {
        var backedUp: Int
        var removed: Int
        var total: Int
    }

    static func forget(profile: String, in session: SteamCloudSession, backupTo backup: URL?) throws -> Result {
        let names = session.list().map(\.name).filter { $0.hasPrefix(profile + "/") }.sorted()
        guard !names.isEmpty else { return Result(backedUp: 0, removed: 0, total: 0) }

        var backedUp = 0
        if let backup {
            let fm = FileManager.default
            try fm.createDirectory(at: backup, withIntermediateDirectories: true)
            for name in names {
                let data = try session.read(name)
                let dest = backup.appendingPathComponent(String(name.dropFirst(profile.count + 1)))
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: dest, options: .atomic)
                backedUp += 1
            }
        }

        var removed = 0
        for name in names where session.delete(name) { removed += 1 }
        return Result(backedUp: backedUp, removed: removed, total: names.count)
    }
}
