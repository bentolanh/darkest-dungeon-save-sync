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
    guard let d = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
    if let s = try? SaveFile(d), let f = s.fields.first(where: { $0.name == "mark" }) {
        let v = f.value
        guard v.count > 4 else { return nil }
        return String(bytes: v[4..<(v.count - 1)], encoding: .utf8)
    }
    return String(data: d, encoding: .utf8)
}
/// A persist.game.json in the game's binary layout, enough for the fields we read.
func gameFile(estate: String, savedAt: String, salt: String = "") -> Data {
    var body = Data()
    func field(_ name: String, _ value: String) {
        body.append(contentsOf: Array((name + "\0").utf8))
        while body.count % 4 != 0 { body.append(0) }
        let v = Array((value + "\0").utf8)
        body.append(contentsOf: [UInt8(v.count & 0xff), UInt8((v.count >> 8) & 0xff), 0, 0])
        body.append(contentsOf: v)
    }
    field("estatename", estate); field("date_time", savedAt); field("salt", salt)
    // A valid, empty save header, with the fields carried in the data section so
    // CampaignInfo's byte scan finds them just as it does in a real file.
    var h = [UInt8](repeating: 0, count: 64); h[0] = 0x01; h[1] = 0xB1
    func put(_ o: Int, _ v: Int) { h[o] = UInt8(v & 0xff); h[o+1] = UInt8((v >> 8) & 0xff) }
    put(8, 64); put(24, 64); put(48, 64); put(56, body.count); put(60, 64)
    return Data(h) + body
}
func makeCampaign(_ dir: URL, estate: String, savedAt: String, roster: String, at date: Date) {
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("persist.game.json")
    try! gameFile(estate: estate, savedAt: savedAt, salt: roster).write(to: url)
    try! fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    writeSave(dir, "persist.roster.json", roster, at: date)
}
func estateOf(_ dir: URL) -> String? { CampaignInfo.read(profileDir: dir).estate }

/// A minimal but genuine save file carrying one marker string, so folders in
/// these tests look to the app exactly as the game's own folders do.
func saveBytes(_ marker: String) -> Data {
    func p32(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)] }
    let name = "mark"
    var value = p32(marker.utf8.count + 1)
    value += Array(marker.utf8); value.append(0)
    let data = Array(name.utf8) + [0] + value
    // The field table carries the name's own hash beside it, as the game writes it.
    let fieldTable = p32(Int(SaveFile.hash(name))) + p32(0) + p32(((name.utf8.count + 1) & 0x1FF) << 2)
    var h = [UInt8](repeating: 0, count: 64); h[0] = 0x01; h[1] = 0xB1
    func put(_ o: Int, _ v: Int) { let b = p32(v); h[o] = b[0]; h[o+1] = b[1]; h[o+2] = b[2]; h[o+3] = b[3] }
    put(8, 64); put(16, 0); put(20, 0); put(24, 64)
    put(44, 1); put(48, 64); put(56, data.count); put(60, 64 + fieldTable.count)
    return Data(h + fieldTable + data)
}

func writeSave(_ dir: URL, _ name: String, _ marker: String, at date: Date) {
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try! saveBytes(marker).write(to: url)
    try! fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
}

func makeProfile(_ dir: URL, game: String, roster: String, at date: Date) {
    writeSave(dir, "persist.game.json", game, at: date)
    writeSave(dir, "persist.roster.json", roster, at: date)
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

print("7b. Campaigns are matched by estate name, not slot number")
clock += 600
check(CampaignInfo.string(after: "estatename", in: gameFile(estate: "Sal", savedAt: "2026-08-24 17:09:07")) == "Sal", "estate name read from the binary layout")
check(CampaignInfo.string(after: "date_time", in: gameFile(estate: "Sal", savedAt: "2026-08-24 17:09:07")) == "2026-08-24 17:09:07", "save time read from the binary layout")
let sal = steam.appendingPathComponent("profile_1"), darkest = steam.appendingPathComponent("profile_0")
try? fm.removeItem(at: sal); try? fm.removeItem(at: darkest)
makeCampaign(darkest, estate: "Darkest", savedAt: "2026-08-22 15:37:54", roster: "d1", at: clock - 300)
makeCampaign(sal, estate: "Sal", savedAt: "2026-08-24 17:09:07", roster: "s1", at: clock - 300)
clock += 10; tick()
check(estateOf(dropbox.appendingPathComponent("profile_1")) == "Sal", "Sal mirrored to slot 2")
// The iPad exports every slot: the old copy of Sal in slot 2, a played-on copy in slot 3, Darkest in slot 1.
clock += 600
let ex = dropbox.appendingPathComponent("20260916_090000_upload")
makeCampaign(ex.appendingPathComponent("profile_0"), estate: "Darkest", savedAt: "2026-08-22 15:37:54", roster: "d1", at: clock - 60)
makeCampaign(ex.appendingPathComponent("profile_1"), estate: "Sal", savedAt: "2026-08-24 17:09:07", roster: "s1", at: clock - 60)
makeCampaign(ex.appendingPathComponent("profile_2"), estate: "Sal", savedAt: "2026-09-16 08:50:00", roster: "s2-ipad", at: clock - 60)
settle()
check(read(sal, "persist.roster.json") == "s2-ipad", "newest Sal copy landed in the Mac's Sal slot")
check(!fm.fileExists(atPath: steam.appendingPathComponent("profile_2").path), "no extra Steam slot was created")
check(read(darkest, "persist.roster.json") == "d1", "Darkest untouched (identical)")
check(engine.status.conflicts.isEmpty, "no conflict")
check(!fm.fileExists(atPath: ex.path), "export archived")
// A campaign the Mac has never seen goes to the first free slot.
clock += 600
let ex2 = dropbox.appendingPathComponent("20260916_100000_upload")
makeCampaign(ex2.appendingPathComponent("profile_3"), estate: "Ravenhold", savedAt: "2026-09-16 09:55:00", roster: "r1", at: clock - 60)
settle()
check(estateOf(steam.appendingPathComponent("profile_2")) == "Ravenhold", "new estate placed in the first free Steam slot")
// An export whose Sal is older than what the Mac holds is a conflict, decided by the game's own save time.
clock += 600
let ex3 = dropbox.appendingPathComponent("20260916_110000_upload")
makeCampaign(ex3.appendingPathComponent("profile_1"), estate: "Sal", savedAt: "2026-08-24 17:09:07", roster: "s1", at: clock)
settle()
check(engine.status.conflicts.count == 1 && engine.status.conflicts[0].estate == "Sal", "older Sal export flagged as a conflict by in-game save time")
engine.resolve(conflict: engine.status.conflicts[0].id, keep: "mac"); Thread.sleep(forTimeInterval: 0.5); tick()
check(read(sal, "persist.roster.json") == "s2-ipad", "Mac's Sal kept")

print("7c. Every campaign is published, with the two edits that let the iPad open it")
clock += 600
// A campaign log holding the record the newer build writes, inside its own entry.
let logLike = dsonFile(
    objects: [(0, 0, 1, 6), (0, 1, 1, 5), (1, 2, 2, 4), (2, 3, 1, 1), (2, 5, 1, 1)],
    fields: [("base_root", true, 0, []), ("chapters", true, 1, []), ("1", true, 2, []),
             ("0", true, 3, []), ("score", false, 0, [1, 0, 0, 0]),
             ("1", true, 4, []), ("trinket_feedback_data", false, 0, [2, 0, 0, 0])])
var log = try! SaveFile(logLike)
check(Sanitise.removeChapterEntries(&log, carrying: "trinket_feedback_data") == 1, "the entry carrying it comes out")
let logOut = log.serialized(); let logBack = try! SaveFile(logOut)
check(logBack.serialized() == logOut && logBack.inconsistencies().isEmpty, "the log still holds together")
check(!logBack.fields.contains { $0.name == "trinket_feedback_data" }, "the record is gone")
check(logBack.fields.contains { $0.name == "score" }, "the chapter's own entry is untouched")
let chapter = logBack.indexOfObject(named: "1", under: "chapters")!
check(logBack.childObjects(ofObject: logBack.fields[chapter].object).map { logBack.fields[$0].name } == ["0"],
      "and what is left is renumbered from zero")

print("7d. The save-file codec reads and rewrites real saves byte for byte")
// A save built the way the game builds one: header, object table, field table, data.
func dsonFile(objects: [(parent: Int, nameField: Int, direct: Int, all: Int)],
              fields: [(name: String, isObject: Bool, object: Int, value: [UInt8])]) -> Data {
    func p32(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)] }
    var data: [UInt8] = [], offs: [Int] = []
    for f in fields { offs.append(data.count); data += Array(f.name.utf8); data.append(0); data += f.value }
    var ot: [UInt8] = []; for o in objects { ot += p32(o.parent) + p32(o.nameField) + p32(o.direct) + p32(o.all) }
    var ft: [UInt8] = []
    for (f, off) in zip(fields, offs) {
        let root = (f.name == "base_root") ? (1 << 31) : 0
        ft += p32(Int(SaveFile.hash(f.name))) + p32(off)
            + p32(root | ((f.object & 0xFFFFF) << 11) | ((f.name.utf8.count + 1) & 0x1FF) << 2 | (f.isObject ? 1 : 0))
    }
    var h = [UInt8](repeating: 0, count: 64); h[0] = 0x01; h[1] = 0xB1
    func put(_ o: Int, _ v: Int) { let p = p32(v); h[o] = p[0]; h[o+1] = p[1]; h[o+2] = p[2]; h[o+3] = p[3] }
    put(8, 64); put(16, ot.count); put(20, objects.count); put(24, 64)
    put(44, fields.count); put(48, 64 + ot.count); put(56, data.count); put(60, 64 + ot.count + ft.count)
    return Data(h + ot + ft + data)
}
// root { buildings { abbey, circus }, tavern }
let town = dsonFile(
    objects: [(0, 0, 2, 4), (0, 1, 2, 2), (1, 2, 0, 0), (1, 3, 0, 0)],
    fields: [("base_root", true, 0, []), ("buildings", true, 1, []),
             ("abbey", true, 2, []), ("circus", true, 3, []),
             ("tavern", false, 0, [3, 0, 0, 0])])
var parsed = try! SaveFile(town)
check(parsed.serialized() == town, "a save is rewritten byte for byte when nothing changes")
check(parsed.indexOfObject(named: "circus") != nil, "the circus object is found")
check(parsed.indexOfObject(named: "circus", under: "buildings") != nil, "and found by its place in the Hamlet")
check(parsed.indexOfObject(named: "circus", under: "base_root") == nil, "but not under the wrong parent")
check(parsed.removeObject(named: "circus", under: "buildings"), "the circus object is removed")
let cleaned = parsed.serialized()
let reparsed = try! SaveFile(cleaned)
check(reparsed.serialized() == cleaned, "the rewritten save parses and rewrites stably")
check(reparsed.indexOfObject(named: "circus") == nil, "the circus is gone")
check(reparsed.fields.map(\.name) == ["base_root", "buildings", "abbey", "tavern"], "every other field survives in order")
check(reparsed.fields.first(where: { $0.name == "tavern" })?.value == [3, 0, 0, 0], "values are carried through untouched")
check(!reparsed.mentions("circus"), "no trace of the name is left in the bytes")
check(reparsed.objects.count == 3 && reparsed.objects[1].direct == 1 && reparsed.objects[1].all == 1,
      "the Hamlet's child counts are corrected")
check(reparsed.objects[0].all == 3, "and so are the totals above it")
check(reparsed.children(of: "buildings") == ["abbey"], "the remaining buildings still read back")
// Two objects sharing a name, as a real save has for "dlc": only the one in the
// named place comes out.
let twins = dsonFile(
    objects: [(0, 0, 2, 4), (0, 1, 1, 1), (1, 2, 0, 0), (0, 3, 1, 1), (3, 4, 0, 0)],
    fields: [("base_root", true, 0, []), ("shown", true, 1, []), ("dlc", true, 2, []),
             ("kept", true, 3, []), ("dlc", true, 4, [])])
var tw = try! SaveFile(twins)
check(tw.serialized() == twins, "the two-of-a-name save round-trips")
check(tw.removeObject(named: "dlc", under: "shown"), "the one under 'shown' is removed")
let twOut = tw.serialized(); let twBack = try! SaveFile(twOut)
check(twBack.indexOfObject(named: "dlc", under: "shown") == nil, "it is gone")
check(twBack.indexOfObject(named: "dlc", under: "kept") != nil, "the other one is untouched")
check(twBack.serialized() == twOut, "and the result is stable")

var damaged = try! SaveFile(town); damaged.objects[3].all = 99
check(damaged.removeObject(named: "circus") == false, "a save whose tables disagree is refused, not half-edited")
var untouched = try! SaveFile(town)
check(untouched.removeObject(named: "nonesuch") == false, "removing something absent changes nothing")
check(untouched.serialized() == town, "and leaves the file exactly as it was")

print("7e. A campaign is published automatically, edited, and not republished until it changes")
clock += 600
let prepSrc = steam.appendingPathComponent("profile_1")
makeCampaign(prepSrc, estate: "Sal", savedAt: "2026-09-18 12:00:00", roster: "s4-mac", at: clock - 100)
clock += 10; tick()
let published = dropbox.appendingPathComponent("profile_1")
check(read(published, "persist.roster.json") == "s4-mac", "it reaches Dropbox on its own, with no asking")
check(engine.status.profiles.first { $0.profile == "profile_1" }?.inStep == true, "and is reported as in step")
// A published copy differs from the Mac save, so "in step" cannot mean "identical".
// It must be remembered by what it was made from, or it would be republished forever.
let publishedAt = read(published, "persist.roster.json")
clock += 10; tick()
check(read(published, "persist.roster.json") == publishedAt, "a later sync leaves it alone")
let engine3 = SyncEngine(config: config, ledgerURL: ledgerURL)
engine3.log = { _ in }
engine3.syncNow(reason: "restart")
check(read(published, "persist.roster.json") == publishedAt, "and so does a restart")
clock += 600
makeCampaign(prepSrc, estate: "Sal", savedAt: "2026-09-19 09:00:00", roster: "s5-mac", at: clock - 100)
clock += 10; tick()
check(read(published, "persist.roster.json") == "s5-mac", "playing on the Mac publishes it again")

print("7g. A folder Dropbox has not finished downloading is never imported")
clock += 600
// The state to protect, and a copy of it to compare against afterwards.
makeCampaign(sal, estate: "Sal", savedAt: "2026-09-20 10:00:00", roster: "precious-mac", at: clock - 200)
writeSave(sal, "persist.town.json", "plain", at: clock - 200)
clock += 20; tick()
let guardExport = dropbox.appendingPathComponent("20260920_100000_upload/profile_1")
try! fm.createDirectory(at: guardExport, withIntermediateDirectories: true)
// Exactly what Dropbox leaves behind before it downloads anything.
for n in ["persist.game.json", "persist.roster.json", "persist.town.json"] {
    fm.createFile(atPath: guardExport.appendingPathComponent(n).path, contents: Data())
}
check(Readiness.check(profileDir: guardExport) == .empty(files: 3), "a folder of placeholders is recognised as not downloaded")
check(Readiness.check(profileDir: guardExport.appendingPathComponent("nope")) == .nothingThere, "a folder that isn't there is not mistaken for one that is")
settle(); settle()
check(read(sal, "persist.roster.json") == "precious-mac", "the Mac campaign is untouched by the empty export")
check(engine.status.waitingForDownload.contains("20260920_100000_upload"), "it is reported as still downloading")
check(fm.fileExists(atPath: dropbox.appendingPathComponent("20260920_100000_upload").path), "and is not archived as done")
// Half of it arrives.
writeSave(guardExport, "persist.game.json", "half", at: clock)
check(Readiness.check(profileDir: guardExport) != .ready, "a part-downloaded folder is still refused")
settle()
check(read(sal, "persist.roster.json") == "precious-mac", "still untouched")
// A file that arrives as something other than a save is refused too.
for n in ["persist.roster.json", "persist.town.json"] {
    try! Data("not a save at all".utf8).write(to: guardExport.appendingPathComponent(n))
}
if case .incomplete = Readiness.check(profileDir: guardExport) { check(true, "a file that is not a save is refused") }
else { check(false, "a file that is not a save is refused") }
settle()
check(read(sal, "persist.roster.json") == "precious-mac", "and nothing is written")
// Now it all arrives properly.
makeCampaign(guardExport, estate: "Sal", savedAt: "2026-09-20 11:00:00", roster: "ipad-real", at: clock)
writeSave(guardExport, "persist.town.json", "plain", at: clock)
check(Readiness.check(profileDir: guardExport) == .ready, "a complete folder is ready")
settle()
check(read(sal, "persist.roster.json") == "ipad-real", "and only then is it imported")
check(!fm.fileExists(atPath: dropbox.appendingPathComponent("20260920_100000_upload").path), "and archived")

print("7i. A hero is a save file of its own, and is cleaned inside")
// A campaign file with both lists: the add-ons the game has shown, and the
// campaign's own. Strings are written in a second pass, once the layout says
// where each value lands, so each carries the padding its footing calls for.
func withStrings(_ data: Data, _ texts: [(Int, String)]) -> Data {
    var save = try! SaveFile(data)
    for (i, text) in texts {
        let pad = (4 - save.fields[i].align) % 4
        var v = [UInt8](repeating: 0, count: pad)
        let n = text.utf8.count + 1
        v += [UInt8(n & 0xff), 0, 0, 0] + Array(text.utf8) + [0]
        save.fields[i].value = v
    }
    return save.serialized()
}
let gameLikeShown = withStrings(dsonFile(
    objects: [(0, 0, 2, 9), (0, 1, 1, 5), (1, 2, 2, 4), (2, 3, 1, 1), (2, 5, 1, 1), (0, 7, 1, 2), (5, 8, 1, 1)],
    fields: [("base_root", true, 0, []),
             ("presented_dlc", true, 1, []), ("dlc", true, 2, []),
             ("0", true, 3, []), ("name", false, 0, [0, 0, 0, 0]),
             ("1", true, 4, []), ("name", false, 0, [0, 0, 0, 0]),
             ("dlc", true, 5, []), ("0", true, 6, []), ("name", false, 0, [0, 0, 0, 0])]),
    [(4, "musketeer"), (6, "arena_mp"), (9, "crimson_court")])

// A hero record, carried inside a roster field as padding, a length, then a file.
let heroInner = dsonFile(
    objects: [(0, 0, 3, 3)],
    fields: [("base_root", true, 0, []), ("name", false, 0, [1, 0, 0, 0]),
             ("trinketId", false, 0, [9, 0, 0, 0]), ("current_hp", false, 0, [4, 0, 0, 0])])
// Build the carrier with room for the hero, then let the writer place it, so the
// padding is whatever this field's footing actually calls for.
var roster = try! SaveFile(dsonFile(
    objects: [(0, 0, 2, 2)],
    fields: [("base_root", true, 0, []), ("version", false, 0, [1, 0, 0, 0]),
             ("raw_data", false, 0, [UInt8](repeating: 0, count: 16))]))
roster.setEmbeddedSave(at: 2, to: try! SaveFile(heroInner))
roster = try! SaveFile(roster.serialized())
let hero = roster.embeddedSave(at: 2)
check(hero != nil, "the hero inside the roster is found and read")
check(hero?.fields.map(\.name) == ["base_root", "name", "trinketId", "current_hp"], "with its own fields")
// A hero is still read and written whole, which is how the roster survives any
// edit to the file that holds it.
let rosterOut = roster.serialized()
let rosterBack = try! SaveFile(rosterOut)
check(rosterBack.serialized() == rosterOut && rosterBack.inconsistencies().isEmpty, "the roster holds together")
let heroBack = rosterBack.embeddedSave(at: 2)
check(heroBack?.fields.map(\.name) == ["base_root", "name", "trinketId", "current_hp"], "the hero comes back whole")
check(heroBack?.fields.first(where: { $0.name == "current_hp" })?.value.prefix(4) == [4, 0, 0, 0], "with its values intact")

// The Butcher's Circus comes out of the record of add-ons already shown; the
// campaign's own list of add-ons is a different object of the same name and is
// never touched, because a campaign asking for add-ons the iPad has not got
// still opens there.
var shown = try! SaveFile(gameLikeShown)
check(Sanitise.addOns(in: shown, under: "presented_dlc") == ["musketeer", "arena_mp"], "both are listed to begin with")
check(Sanitise.removeAddOn(&shown, named: "arena_mp", from: "presented_dlc"), "the Circus comes out")
let shownOut = shown.serialized(); let shownBack = try! SaveFile(shownOut)
check(shownBack.serialized() == shownOut && shownBack.inconsistencies().isEmpty, "the file holds together")
check(Sanitise.addOns(in: shownBack, under: "presented_dlc") == ["musketeer"], "and only that one is gone")
check(Sanitise.addOns(in: shownBack, under: "base_root") == ["crimson_court"], "the campaign's own list is untouched")

// No object may come out of an edit carrying bytes of its own.
func objectsWithBytes(_ d: Data) -> Int {
    (try! SaveFile(d)).fields.filter { $0.isObject && !$0.value.isEmpty }.count
}
check(objectsWithBytes(town) == 0, "a save the game wrote has no such object")
var padTest = try! SaveFile(gameLikeShown)
check(padTest.removeObject(named: "dlc", under: "presented_dlc"), "remove something ahead of an object")
let padOut = padTest.serialized()
check(objectsWithBytes(padOut) == 0, "and none appears after the edit")
check((try! SaveFile(padOut)).inconsistencies().isEmpty, "the result passes its own check")
var padTest2 = try! SaveFile(town)
check(padTest2.removeObject(named: "circus", under: "buildings"), "remove an object from the Hamlet")
check(objectsWithBytes(padTest2.serialized()) == 0, "still none")

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
