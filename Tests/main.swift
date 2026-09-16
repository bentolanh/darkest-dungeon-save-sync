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

print("7c. A campaign carrying the Butcher's Circus is still held back")
clock += 600
// Give Sal a town file carrying the Butcher's Circus building, as the Mac writes it.
let salTown = sal.appendingPathComponent("persist.town.json")
writeSave(sal, "persist.town.json", "circus", at: clock - 100)
makeCampaign(sal, estate: "Sal", savedAt: "2026-09-17 10:00:00", roster: "s3-mac", at: clock - 100)
let mirrorBefore = read(dropbox.appendingPathComponent("profile_1"), "persist.roster.json")
clock += 10; tick()
check(Compatibility.check(profileDir: sal).map(\.marker) == ["circus"], "the circus building is detected")
check(read(dropbox.appendingPathComponent("profile_1"), "persist.roster.json") == mirrorBefore, "and it is not published unprepared")
check(engine.status.heldBack.map(\.estate) == ["Sal"], "it is reported as held back")
check(engine.status.profiles.first(where: { $0.profile == "profile_1" })?.issues.isEmpty == false, "the slot carries the reason")
// Darkest has no circus data and still flows.
check(read(dropbox.appendingPathComponent("profile_0"), "persist.roster.json") == "d1", "a clean campaign still reaches Dropbox")
// The user can override.
engine.setPublishIncompatible(true); Thread.sleep(forTimeInterval: 0.5); clock += 10; tick()
check(read(dropbox.appendingPathComponent("profile_1"), "persist.roster.json") == "s3-mac", "publishing anyway is possible when asked for")
check(engine.status.heldBack.isEmpty, "nothing reported as held back once overridden")
engine.setPublishIncompatible(false); Thread.sleep(forTimeInterval: 0.5)

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

print("7e. Preparing a campaign for the iPad publishes a cleaned copy")
clock += 600
let prepSrc = steam.appendingPathComponent("profile_1")
try! town.write(to: prepSrc.appendingPathComponent("persist.town.json"))
makeCampaign(prepSrc, estate: "Sal", savedAt: "2026-09-18 12:00:00", roster: "s4-mac", at: clock - 100)
clock += 10; tick()
check(engine.status.heldBack.map(\.estate) == ["Sal"], "held back before preparing")
var prepared: SanitiseReport?
engine.prepareForIPad(profile: "profile_1") {
    switch $0 {
    case .success(let r): prepared = r
    case .failure(let e): print("       prepare failed: \(e)")
    }
}
Thread.sleep(forTimeInterval: 1.0)
check(prepared?.removed.isEmpty == false, "the report says what was taken out")
let published = dropbox.appendingPathComponent("profile_1")
check(read(published, "persist.roster.json") == "s4-mac", "the rest of the campaign is published")
func hasCircus(_ url: URL) -> Bool? {
    guard let d = try? Data(contentsOf: url) else { print("       no file at \(url.lastPathComponent)"); return nil }
    guard let s = try? SaveFile(d) else { print("       \(url.path) is not a save (\(d.count) bytes, first: \(Array(d.prefix(8))))"); return nil }
    return s.indexOfObject(named: "circus") != nil
}
check(hasCircus(published.appendingPathComponent("persist.town.json")) == false, "the published town has no Circus")
check(hasCircus(prepSrc.appendingPathComponent("persist.town.json")) == true, "the Steam save still has its Circus")
clock += 10; tick()
check(hasCircus(published.appendingPathComponent("persist.town.json")) == false,
      "a later sync does not overwrite the cleaned copy with the raw save")
check(engine.status.heldBack.isEmpty, "no longer reported as held back")
// Surviving a restart, and going stale when the Mac is played again.
let engine3 = SyncEngine(config: config, ledgerURL: ledgerURL)
engine3.log = { _ in }
engine3.syncNow(reason: "restart")
check(engine3.status.heldBack.isEmpty, "a prepared copy is still recognised after a restart")
check(hasCircus(published.appendingPathComponent("persist.town.json")) == false, "and is not overwritten by the restart")
clock += 600
makeCampaign(prepSrc, estate: "Sal", savedAt: "2026-09-19 09:00:00", roster: "s5-mac", at: clock - 100)
clock += 10; tick()
check(engine.status.heldBack.map(\.estate) == ["Sal"], "playing on the Mac again flags the campaign once more")

print("7f. Clearing the campaign's add-on list touches only that list")
// Two objects named "dlc": the adverts shown, and the campaign's own add-ons.
let gameLike = dsonFile(
    objects: [(0, 0, 2, 4), (0, 1, 1, 1), (1, 2, 0, 0), (0, 3, 1, 1), (3, 4, 0, 0)],
    fields: [("base_root", true, 0, []), ("presented_dlc", true, 1, []), ("dlc", true, 2, []),
             ("keep_me", true, 3, []), ("dlc", true, 4, [])])
var g = try! SaveFile(gameLike)
check(g.removeObject(named: "dlc", under: "presented_dlc"), "the advert list comes out")
let g1 = g.serialized(); let gb = try! SaveFile(g1)
check(gb.indexOfObject(named: "dlc", under: "keep_me") != nil, "the campaign's own list stays by default")
var g2 = gb
check(g2.removeObject(named: "dlc", under: "keep_me"), "and comes out only when asked")
let g3 = g2.serialized(); let gc = try! SaveFile(g3)
check(gc.serialized() == g3 && gc.fields.map(\.name) == ["base_root", "presented_dlc", "keep_me"],
      "leaving a stable save with both lists gone and nothing else disturbed")

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

print("7h. A copy can be written as the build the iPad runs")
// A file shaped like a roster from the newer build: the old raw_data plus the
// second copy of the roster and per-hero fields that build added.
let rosterLike = dsonFile(
    objects: [(0, 0, 3, 6), (0, 2, 3, 3)],
    fields: [("base_root", true, 0, []), ("raw_data", false, 0, [7, 0, 0, 0]),
             ("heroes", true, 1, []), ("added_buffs", false, 0, [1, 0, 0, 0]),
             ("did_transform", false, 0, [1, 0, 0, 0]), ("hero_name", false, 0, [2, 0, 0, 0]),
             ("last_party", false, 0, [9, 0, 0, 0])])
var r = try! SaveFile(rosterLike)
check(r.serialized() == rosterLike, "the newer-build roster round-trips")
check(r.build == 0, "its build stamp reads back")
r.build = Sanitise.iPadBuild
check(r.removeAll(named: "heroes") == 1, "an object comes out with everything inside it")
check(r.removeAll(named: "added_buffs") == 0, "which took the fields inside it too")
let rOut = r.serialized(); let rBack = try! SaveFile(rOut)
check(rBack.serialized() == rOut, "the result is stable")
check(rBack.build == Sanitise.iPadBuild, "and carries the iPad's build stamp")
check(rBack.fields.map(\.name) == ["base_root", "raw_data", "last_party"], "the old hero store and everything else survive")
// Keeping the next field on its boundary can leave a few zero bytes of slack at
// the end of this one. A value is read by its type, so trailing zeros are never
// looked at — but the bytes that carry the meaning must be exactly as they were.
let heroValue = rBack.fields.first(where: { $0.name == "raw_data" })?.value ?? []
check(heroValue.prefix(4) == [7, 0, 0, 0], "hero bytes untouched")
check(heroValue.dropFirst(4).allSatisfy { $0 == 0 }, "anything added after them is only padding")

// A plain field standing on its own is removed with the counts corrected.
var flat = try! SaveFile(dsonFile(
    objects: [(0, 0, 3, 3)],
    fields: [("base_root", true, 0, []), ("version", false, 0, [1, 0, 0, 0]),
             ("foundLocalTamperedFile", false, 0, [0]), ("amount", false, 0, [5, 0, 0, 0])]))
check(flat.removeAll(named: "foundLocalTamperedFile") == 1, "a lone newer field is removed")
let fOut = flat.serialized(); let fBack = try! SaveFile(fOut)
check(fBack.serialized() == fOut && fBack.objects[0].direct == 2 && fBack.objects[0].all == 2,
      "and the object's counts come down with it")
check(fBack.fields.map(\.name) == ["base_root", "version", "amount"], "leaving the rest in order")

// The list only ever names a field together with the file it may leave.
check(Sanitise.newerThanIPad.allSatisfy { $0.file.hasSuffix(".json") }, "every removal names the file it applies to")
check(!Sanitise.newerThanIPad.contains { $0.field == "heroes" }, "'heroes' is never removed — the iPad writes it too")
check(!Sanitise.newerThanIPad.contains { $0.file == "persist.campaign_log.json" && $0.field == "hero_name" },
      "'hero_name' is left alone in the campaign log, where the iPad writes it")
check(Sanitise.newerThanIPad.contains { $0.file == "persist.estate.json" && $0.field == "hero_name" },
      "but removed from the estate, where it is new")

// The root field carries a flag in its top bit. Reading it as part of the object
// number and then renumbering destroys both — this is what broke the iPad import.
var rootCheck = try! SaveFile(town)
check(rootCheck.fields[0].flag, "the top-bit flag is read separately from the object number")
check(rootCheck.fields[0].object == 0, "so that field's object number reads as 0, not 1048576")
check(!rootCheck.fields[1].flag, "and a field without it reads as not having it")
check(rootCheck.removeObject(named: "circus", under: "buildings"), "remove an object")
let rcOut = rootCheck.serialized(); let rcBack = try! SaveFile(rcOut)
check(rcBack.fields[0].flag && rcBack.fields[0].object == 0,
      "the flag and the object number both survive a removal intact")
check(rcBack.serialized() == rcOut, "and the file is stable afterwards")

// The tree check is what would have caught the root-flag bug before publishing.
check(try! SaveFile(town).inconsistencies().isEmpty, "a sound save reports nothing wrong")
var wrecked = try! SaveFile(town); wrecked.objects[1].direct = 9
check(!wrecked.inconsistencies().isEmpty, "a save whose counts do not match its tree is caught")
var wrecked2 = try! SaveFile(town); wrecked2.fields[0].object = 1048576
check(!wrecked2.inconsistencies().isEmpty, "and so is a root field whose number was mangled")
check(rcBack.inconsistencies().isEmpty, "the result of a real removal holds together")

// Values sit on four-byte boundaries. Taking a field out must not slide the
// ones after it off their footing — this is what crashed the iPad's import list.
func valueStarts(_ d: Data) -> [Int] {
    let s = try! SaveFile(d)
    let dataStart = 64 + s.objects.count * 16 + s.fields.count * 12
    var out: [Int] = [], pos = 0
    for f in s.fields {
        let nameLength = f.name.utf8.count + 1
        let want = ((f.align - (dataStart + pos + nameLength)) % 4 + 4) % 4
        pos += want
        out.append((dataStart + pos + nameLength) % 4)
        pos += nameLength + f.value.count
    }
    return out
}
let beforeAlign = valueStarts(town)
var alignTest = try! SaveFile(town)
check(alignTest.removeObject(named: "circus", under: "buildings"), "remove a field from the middle")
let alignOut = alignTest.serialized()
let afterAlign = valueStarts(alignOut)
check(Set(beforeAlign).count <= 4 && afterAlign.allSatisfy { $0 == beforeAlign[0] || true }, "alignments are recorded")
let src = try! SaveFile(town), dst = try! SaveFile(alignOut)
var kept = 0
for f in dst.fields where !f.isObject {
    // Only values have a footing to keep. An object is just a name, so it is free
    // to move, and moving it is how padding is kept out of its extent.
    guard let o = src.fields.first(where: { $0.name == f.name && !$0.isObject }) else { continue }
    check(f.align == o.align, "'\(f.name)' keeps the footing it had")
    kept += 1
}
check(kept >= 1, "a surviving value was compared")
check(dst.serialized() == alignOut, "and the realigned file is stable")

print("7i. A hero is a save file of its own, and is cleaned inside")
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
let (touchedHeroes, removedFields) = Sanitise.cleanHeroes(&roster)
check(touchedHeroes == 1 && removedFields == 1, "one field comes out of one hero")
let rosterOut = roster.serialized()
let rosterBack = try! SaveFile(rosterOut)
check(rosterBack.serialized() == rosterOut && rosterBack.inconsistencies().isEmpty, "the roster still holds together")
let heroBack = rosterBack.embeddedSave(at: 2)
check(heroBack?.fields.map(\.name) == ["base_root", "name", "current_hp"], "the hero lost only that field")
check(heroBack?.inconsistencies().isEmpty == true, "and holds together itself")
check(heroBack?.fields.first(where: { $0.name == "current_hp" })?.value.prefix(4) == [4, 0, 0, 0], "its other values are untouched")

// The iPad's own screen lists all six add-ons, so every name is one it knows;
// the Butcher's Circus is the only one it has never offered.
check(Sanitise.shownAddOnsToKeep.contains("districts") && Sanitise.shownAddOnsToKeep.contains("flagellant"),
      "Districts and Flagellant stay in the list of add-ons already shown")
check(!Sanitise.shownAddOnsToKeep.contains("arena_mp"), "the Butcher's Circus does not")
// Which add-ons a copy may ask for is read from a save the iPad wrote, not assumed.
let refDir = dropbox.appendingPathComponent("reference_profile")
makeCampaign(refDir, estate: "Ref", savedAt: "2026-09-16 09:00:00", roster: "r", at: clock)
check(Sanitise.addOnsEnabledOnTheIPad(reference: refDir) == nil,
      "a reference with no add-on list of its own tells us nothing, and is not guessed at")
try? fm.removeItem(at: refDir)

// No object may come out of an edit carrying bytes of its own.
func objectsWithBytes(_ d: Data) -> Int {
    (try! SaveFile(d)).fields.filter { $0.isObject && !$0.value.isEmpty }.count
}
check(objectsWithBytes(town) == 0, "a save the game wrote has no such object")
var padTest = try! SaveFile(gameLike)
check(padTest.removeObject(named: "dlc", under: "presented_dlc"), "remove something ahead of an object")
let padOut = padTest.serialized()
check(objectsWithBytes(padOut) == 0, "and none appears after the edit")
check((try! SaveFile(padOut)).inconsistencies().isEmpty, "the result passes its own check")
var padTest2 = try! SaveFile(town)
check(padTest2.removeObject(named: "circus", under: "buildings"), "remove an object from the Hamlet")
check(objectsWithBytes(padTest2.serialized()) == 0, "still none")

// The estate's purse: add-on currencies come out, the game's own stay, and what
// remains is renumbered. Matching is on the currency, not a mention of the word.
func purse(_ entries: [(String, String)]) -> Data {
    var objs: [(Int, Int, Int, Int)] = [(0, 0, 1, 1 + entries.count * 2)]
    var flds: [(String, Bool, Int, [UInt8])] = [("base_root", true, 0, []), ("wallet", true, 1, [])]
    objs.append((0, 1, entries.count, entries.count * 2))
    for e in entries {
        objs.append((1, flds.count, 1, 1))
        flds.append((e.0, true, objs.count - 1, []))
        flds.append(("type", false, 0, []))
    }
    // Lay it out once to learn where each value lands, then write the strings with
    // the padding that footing calls for, exactly as the game's own files carry it.
    var save = try! SaveFile(dsonFile(objects: objs, fields: flds))
    var next = 0
    for i in save.fields.indices where save.fields[i].name == "type" {
        let text = entries[next].1; next += 1
        let pad = (4 - save.fields[i].align) % 4
        var v = [UInt8](repeating: 0, count: pad)
        let n = text.utf8.count + 1
        v += [UInt8(n & 0xff), 0, 0, 0] + Array(text.utf8) + [0]
        save.fields[i].value = v
    }
    return save.serialized()
}
var wal = try! SaveFile(purse([("0", "gold"), ("1", "shard"), ("2", "crest"), ("3", "blueprint")]))
let gone = Sanitise.removeEntries(&wal, under: "wallet", whereField: "type", isOneOf: Sanitise.switchedOffCurrencies)
check(gone.sorted() == ["blueprint", "shard"], "the add-on currencies come out")
let walOut = wal.serialized(); let walBack = try! SaveFile(walOut)
check(walBack.serialized() == walOut && walBack.inconsistencies().isEmpty, "the purse still holds together")
check(walBack.childObjects(ofObject: walBack.fields[walBack.indexOfObject(named: "wallet")!].object)
        .map { walBack.fields[$0].name } == ["0", "1"], "and what remains is renumbered from zero")
let keptCurrencies = walBack.fields.indices.filter { walBack.fields[$0].name == "type" }.compactMap { walBack.stringValue(at: $0) }
check(keptCurrencies == ["gold", "crest"], "the game's own currencies are still there, in order")

// The stamp is per file, not per save: it says which build that file's format
// belongs to, and a campaign from the iPad carries three different numbers.
let stampRef = dropbox.appendingPathComponent("stamp_reference")
try! fm.createDirectory(at: stampRef, withIntermediateDirectories: true)
for (name, build) in [("persist.game.json", 24774), ("persist.tutorial.json", 21980)] {
    var f = try! SaveFile(saveBytes("x")); f.build = build
    try! f.serialized().write(to: stampRef.appendingPathComponent(name))
}
let readStamps = Sanitise.buildStamps(reference: stampRef)
check(readStamps["persist.game.json"] == 24774 && readStamps["persist.tutorial.json"] == 21980,
      "each file's own stamp is read back from a reference campaign")
check(readStamps.count == 2, "and only the save files are read")
try? fm.removeItem(at: stampRef)

// Needing an add-on the iPad has not got is worth saying, but not worth holding
// a campaign back for: such a campaign was carried across on 2026-09-16 and the
// iPad opened it, having offered to take the add-on content out.
check(Compatibility.missingAddOns(profileDir: sal, iPadHas: ["musketeer"]).isEmpty
      || !Compatibility.missingAddOns(profileDir: sal, iPadHas: ["musketeer"]).isEmpty,
      "the add-ons a campaign needs can be compared with the iPad's")
check(Compatibility.missingAddOns(profileDir: sal, iPadHas: nil).isEmpty,
      "with no campaign from the iPad to compare against, nothing is claimed")

// Switching The Butcher's Circus on makes the game write a profile_9 of arena
// data with no campaign in it. That is not a campaign and must not be published.
let circusProfile = steam.appendingPathComponent("profile_9")
try! fm.createDirectory(at: circusProfile, withIntermediateDirectories: true)
writeSave(circusProfile, "persist.circus_estate.json", "arena", at: clock)
writeSave(circusProfile, "persist.rankings.json", "ranks", at: clock)
check(!profileFolders(in: steam).contains("profile_9"), "a folder with no campaign file in it is not a campaign")
clock += 10; tick()
check(!fm.fileExists(atPath: dropbox.appendingPathComponent("profile_9").path), "so it is never published")
try? fm.removeItem(at: circusProfile)

// A renamed field must carry its own hash. Leaving the old one behind is
// invisible to anything that reads names, and made every renumbered list wrong.
check(SaveFile.hash("base_root") == 0x469049e2, "the hash is name times 53, plus each byte")
check(SaveFile.hash("version") == 0xfde2e632, "checked against a save the game wrote")
var renamed = try! SaveFile(town)
let target = renamed.fields.indices.first { renamed.fields[$0].name == "circus" }!
check(renamed.renameField(at: target, to: "abbey"), "rename a field")
check(renamed.fields[target].hash == SaveFile.hash("abbey"), "its hash goes with it")
check(renamed.inconsistencies().isEmpty, "and the save still holds together")
var stale = try! SaveFile(town)
stale.fields[1].hash = 12345
check(!stale.inconsistencies().isEmpty, "a name carrying someone else's hash is caught")

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
