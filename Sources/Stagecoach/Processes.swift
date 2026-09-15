// Who else is touching the save folders right now: the game itself (never
// write under it while it runs) and the Steam client (needed for a cloud push).

import AppKit
import Foundation

enum Processes {
    static var steamIsRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.valvesoftware.steam" }
    }

    static var gameIsRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
            let name = (app.localizedName ?? "").lowercased()
            let bundle = (app.bundleIdentifier ?? "").lowercased()
            let appName = (app.bundleURL?.lastPathComponent ?? "").lowercased()
            return name == "darkest dungeon" || name.hasPrefix("darkest dungeon")
                || bundle.contains("darkestdungeon") || appName.hasPrefix("darkest dungeon")
        }
    }
}
