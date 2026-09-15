// Exercises the sync engine against temporary folders standing in for the
// Steam side and the Dropbox side. Run with ./run_tests.sh.

import Foundation

var failures = 0
func check(_ cond: Bool, _ msg: String, line: Int = #line) {
    if cond { print("  ok   \(msg)") } else { failures += 1; print("  FAIL \(msg) (line \(line))") }
}

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("stagecoach-test-\(UUID().uuidString)")
let steam = root.appendingPathComponent("remote")
let dropbox = root.appendingPathComponent("Dropbox/Apps/DarkestDungeon")
let archive = root.appendingPathComponent("Dropbox/Darkest Dungeon Save Sync/Imported exports")
let backups = root.appendingPathComponent("Backups")
try! fm.createDirectory(at: steam, withIntermediateDirectories: true)
try! fm.createDirectory(at: dropbox, withIntermediateDirectories: true)

var clock = Date(timeIntervalSince1970: 1_800_000_000)
var gameRunning = false

func write(_ dir: URL, _ name: String, _ text: String, at date: Date) {
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try! text.data(using: .utf8)!.write(to: url)
    try! fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
}
func read(_ dir: URL, _ name: String) -> String? {
    (try? Data(contentsOf: dir.appendingPathComponent(name))).flatMap { String(data: $0, encoding: .utf8) }
}
func makeProfile(_ dir: URL, game: String, roster: String, at date: Date) {
    write(dir, "persist.game.json", game, at: date)
    write(dir, "persist.roster.json", roster, at: date)
}

var config = SyncConfig(steamRemote: steam, dropboxFolder: dropbox, archiveFolder: archive, backupsFolder: backups, steamworksLibrary: nil)
config.cloudPush = false
config.quietSeconds = 5
config.gameIsRunning = { gameRunning }
config.steamIsRunning = { false }
config.now = { clock }
let ledgerURL = root.appendingPathComponent("ledger.json")
let engine = SyncEngine(config: config, ledgerURL: ledgerURL)
engine.log = { print("       log: \($0)") }
func tick() { engine.syncNow(reason: "test") }
func settle() { tick(); clock += 6; tick() }   // export folders need one quiet period

print("1. First run: an old export sits in Dropbox, the Mac save is newer")
makeProfile(steam.appendingPathComponent("profile_1"), game: "mac-v2", roster: "mac-v2", at: clock - 3600)
write(steam.appendingPathComponent("profile_1/backup"), "persist.game.json", "old", at: clock - 7200)
makeProfile(dropbox.appendingPathComponent("20260811_153851_upload/profile_1"), game: "ipad-v1", roster: "ipad-v1", at: clock - 86400)
settle()
check(read(steam.appendingPathComponent("profile_1"), "persist.game.json") == "mac-v2", "Mac save untouched")
check(read(dropbox.appendingPathComponent("profile_1"), "persist.game.json") == "mac-v2", "Mac save mirrored to Dropbox root")
check(!fm.fileExists(atPath: dropbox.appendingPathComponent("20260811_153851_upload").path), "old export moved out of Apps/DarkestDungeon")
check(fm.fileExists(atPath: archive.appendingPathComponent("20260811_153851_upload/profile_1/persist.game.json").path), "old export is in the archive")
check(!fm.fileExists(atPath: dropbox.appendingPathComponent("profile_1/backup").path), "game's backup/ subfolder not mirrored")
check(engine.status.conflicts.isEmpty, "no conflict on first run")
check(engine.ledger.profiles["profile_1"]?.lastSource == "mac", "ledger records the Mac as the source")

print("1b. First run for another slot: the export is newer than the Mac save")
makeProfile(steam.appendingPathComponent("profile_2"), game: "mac-old", roster: "mac-old", at: clock - 86400)
makeProfile(dropbox.appendingPathComponent("20260901_090000_upload/profile_2"), game: "ipad-new", roster: "ipad-new", at: clock - 3600)
settle()
check(read(steam.appendingPathComponent("profile_2"), "persist.game.json") == "ipad-new", "newer export imported on first run")
check(read(dropbox.appendingPathComponent("profile_2"), "persist.game.json") == "ipad-new", "and mirrored")
try? fm.removeItem(at: steam.appendingPathComponent("profile_2")); try? fm.removeItem(at: dropbox.appendingPathComponent("profile_2"))
try? fm.removeItem(at: backups)

print("2. The Mac game saves again")
clock += 60
makeProfile(steam.appendingPathComponent("profile_1"), game: "mac-v3", roster: "mac-v3", at: clock)
tick()
check(read(dropbox.appendingPathComponent("profile_1"), "persist.game.json") == "mac-v2", "not mirrored while the save is still fresh")
clock += 10
tick()
check(read(dropbox.appendingPathComponent("profile_1"), "persist.game.json") == "mac-v3", "mirrored once quiet")

print("3. The iPad exports newer progress (Mac unchanged since the last sync)")
clock += 600
makeProfile(dropbox.appendingPathComponent("20260915_120000_upload/profile_1"), game: "ipad-v4", roster: "ipad-v4", at: clock - 30)
tick()
check(read(steam.appendingPathComponent("profile_1"), "persist.game.json") == "mac-v3", "not imported before the export settles")
check(engine.status.waitingForDownload == ["20260915_120000_upload"], "reports waiting for Dropbox")
clock += 6
tick()
check(read(steam.appendingPathComponent("profile_1"), "persist.game.json") == "ipad-v4", "imported into the Steam side")
check(read(steam.appendingPathComponent("profile_1/backup"), "persist.game.json") == "old", "game's own backup/ left alone")
check(read(dropbox.appendingPathComponent("profile_1"), "persist.game.json") == "ipad-v4", "Dropbox root updated to match")
check(!fm.fileExists(atPath: dropbox.appendingPathComponent("20260915_120000_upload").path), "export archived")
let backupDirs = (try? fm.contentsOfDirectory(atPath: backups.path)) ?? []
check(backupDirs.count == 1 && read(backups.appendingPathComponent(backupDirs[0] + "/profile_1"), "persist.game.json") == "mac-v3", "the overwritten Mac save was backed up")
check(engine.ledger.profiles["profile_1"]?.lastSource == "ipad", "ledger records the iPad as the source")
check(engine.ledger.profiles["profile_1"]?.cloudState == "pendingGameLaunch", "cloud state: waits for the next game launch (no Steam)")

print("4. Both sides move on → conflict, resolved for the iPad")
clock += 600
makeProfile(steam.appendingPathComponent("profile_1"), game: "mac-v5", roster: "mac-v5", at: clock - 100)
tick()
check(read(dropbox.appendingPathComponent("profile_1"), "persist.game.json") == "mac-v5", "Mac progress mirrored")
makeProfile(dropbox.appendingPathComponent("20260915_130000_upload/profile_1", isDirectory: true), game: "ipad-v6", roster: "ipad-v6", at: clock - 50)
settle()
check(read(steam.appendingPathComponent("profile_1"), "persist.game.json") == "ipad-v6", "export imported when the Mac hasn't moved since the last sync")
clock += 600
makeProfile(steam.appendingPathComponent("profile_1"), game: "mac-v7", roster: "mac-v7", at: clock - 1)   // fresh: not yet mirrored
makeProfile(dropbox.appendingPathComponent("20260915_140000_upload/profile_1"), game: "ipad-v8", roster: "ipad-v8", at: clock)
settle()
check(engine.status.conflicts.count == 1, "conflict detected when both changed")
check(read(steam.appendingPathComponent("profile_1"), "persist.game.json") == "mac-v7", "nothing written to Steam during a conflict")
check(read(dropbox.appendingPathComponent("profile_1"), "persist.game.json") == "ipad-v6", "nothing mirrored during a conflict")
check(fm.fileExists(atPath: dropbox.appendingPathComponent("20260915_140000_upload").path), "export kept until resolved")
engine.resolve(conflict: "20260915_140000_upload/profile_1", keep: "ipad")
Thread.sleep(forTimeInterval: 0.5)
tick()
check(engine.status.conflicts.isEmpty, "conflict cleared")
check(read(steam.appendingPathComponent("profile_1"), "persist.game.json") == "ipad-v8", "iPad save won")
check(read(dropbox.appendingPathComponent("profile_1"), "persist.game.json") == "ipad-v8", "mirror follows")

print("4b. An export older than the save the Mac already held is a conflict, not an import")
clock += 600
makeProfile(steam.appendingPathComponent("profile_1"), game: "mac-v8b", roster: "mac-v8b", at: clock - 100)
tick()
check(read(dropbox.appendingPathComponent("profile_1"), "persist.game.json") == "mac-v8b", "Mac progress mirrored")
makeProfile(dropbox.appendingPathComponent("20260915_145000_upload/profile_1"), game: "ipad-stale", roster: "ipad-stale", at: clock - 5000)
settle()
check(engine.status.conflicts.count == 1, "stale export flagged as a conflict")
engine.resolve(conflict: "20260915_145000_upload/profile_1", keep: "mac")
Thread.sleep(forTimeInterval: 0.5); tick()
check(engine.status.conflicts.isEmpty && read(steam.appendingPathComponent("profile_1"), "persist.game.json") == "mac-v8b", "Mac save kept")

print("5. Conflict resolved for the Mac")
clock += 600
makeProfile(steam.appendingPathComponent("profile_1"), game: "mac-v9", roster: "mac-v9", at: clock - 1)
makeProfile(dropbox.appendingPathComponent("20260915_150000_upload/profile_1"), game: "ipad-v10", roster: "ipad-v10", at: clock)
settle()
check(engine.status.conflicts.count == 1, "conflict detected")
engine.resolve(conflict: "20260915_150000_upload/profile_1", keep: "mac")
Thread.sleep(forTimeInterval: 0.5)
clock += 6; tick()
check(read(steam.appendingPathComponent("profile_1"), "persist.game.json") == "mac-v9", "Mac save kept")
check(read(dropbox.appendingPathComponent("profile_1"), "persist.game.json") == "mac-v9", "Mac save mirrored for the iPad")
check(!fm.fileExists(atPath: dropbox.appendingPathComponent("20260915_150000_upload").path), "losing export archived")

print("6. The game is running when an export lands")
clock += 600
gameRunning = true
makeProfile(dropbox.appendingPathComponent("20260915_160000_upload/profile_1"), game: "ipad-v11", roster: "ipad-v11", at: clock)
settle()
check(read(steam.appendingPathComponent("profile_1"), "persist.game.json") == "mac-v9", "not imported while the game runs")
check(engine.status.waitingForGameToQuit, "reports waiting for the game to quit")
gameRunning = false
tick()
check(read(steam.appendingPathComponent("profile_1"), "persist.game.json") == "ipad-v11", "imported after the game quit")

print("7. A second campaign slot appears on the Mac")
clock += 600
makeProfile(steam.appendingPathComponent("profile_0"), game: "slot0", roster: "slot0", at: clock - 60)
tick()
check(read(dropbox.appendingPathComponent("profile_0"), "persist.game.json") == "slot0", "new slot mirrored")
check(engine.status.profiles.map(\.profile) == ["profile_0", "profile_1"], "both slots reported")

print("8. Ledger survives a restart")
let engine2 = SyncEngine(config: config, ledgerURL: ledgerURL)
check(engine2.ledger.profiles.keys.sorted() == engine.ledger.profiles.keys.sorted()
      && engine2.ledger.profiles.mapValues(\.syncedDigest) == engine.ledger.profiles.mapValues(\.syncedDigest)
      && engine2.ledger.processedExports == engine.ledger.processedExports
      && engine2.ledger.conflicts.map(\.id) == engine.ledger.conflicts.map(\.id), "ledger reloaded with the same digests, exports and conflicts")
if let a = engine.ledger.profiles["profile_1"]?.syncedSaveTime, let b = engine2.ledger.profiles["profile_1"]?.syncedSaveTime {
    check(abs(a.timeIntervalSince(b)) < 0.001, "save times survive the round trip to within a millisecond")
}

try? fm.removeItem(at: root)
print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
