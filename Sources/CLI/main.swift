// stagecoach-cli: the same machinery without the menu bar, for checking a
// setup or watching one sync pass from a terminal.
//
//   stagecoach-cli scan               what was detected, and the state of each side
//   stagecoach-cli steam-check        open a Steam session as Darkest Dungeon and list cloud files
//   stagecoach-cli steam-write-test   read steam_init.json from the cloud and write it back unchanged
//   stagecoach-cli sync               run one sync pass with the real folders and ledger
//   stagecoach-cli steam-push <profile_N> [folder]
//                                     write a profile folder into Steam Cloud through the client
//                                     (default: the Steam side's own copy, i.e. re-push as is)

import Foundation

let args = CommandLine.arguments.dropFirst()
let command = args.first ?? "scan"

func hr(_ d: Date?) -> String {
    guard let d else { return "–" }
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f.string(from: d)
}

switch command {
case "scan":
    let steam = Paths.detectSteamRemote()
    let dropbox = Paths.detectDropboxAppFolder()
    let lib = Paths.detectSteamworksLibrary()
    print("Steam save folder:   \(steam?.path ?? "not found")")
    print("Dropbox folder:      \(dropbox?.path ?? "not found")")
    print("Steamworks library:  \(lib?.path ?? "not found")")
    print("Steam running:       \(Processes.steamIsRunning)")
    print("Game running:        \(Processes.gameIsRunning)")
    if let steam {
        print("\nSteam side:")
        for p in profileFolders(in: steam) {
            let s = Snapshot.read(steam.appendingPathComponent(p))
            print("  \(p): \(s?.files.count ?? 0) files, newest \(hr(s?.newestModified)), digest \(s?.digest.prefix(12) ?? "-")")
        }
    }
    if let dropbox {
        print("\nDropbox side:")
        for p in profileFolders(in: dropbox) {
            let s = Snapshot.read(dropbox.appendingPathComponent(p))
            print("  \(p): \(s?.files.count ?? 0) files, newest \(hr(s?.newestModified)), digest \(s?.digest.prefix(12) ?? "-")")
        }
        let exports = ((try? FileManager.default.contentsOfDirectory(atPath: dropbox.path)) ?? []).filter(isExportFolder).sorted()
        for e in exports {
            print("  export \(e):")
            for p in profileFolders(in: dropbox.appendingPathComponent(e)) {
                let s = Snapshot.read(dropbox.appendingPathComponent(e).appendingPathComponent(p))
                print("    \(p): \(s?.files.count ?? 0) files, newest \(hr(s?.newestModified)), digest \(s?.digest.prefix(12) ?? "-")")
            }
        }
    }
    let ledger = Ledger.load()
    print("\nLedger (\(Ledger.url.path)):")
    for (p, r) in ledger.profiles.sorted(by: { $0.key < $1.key }) {
        print("  \(p): synced \(hr(r.syncedAt)) from \(r.lastSource), digest \(r.syncedDigest.prefix(12)), cloud \(r.cloudState)")
    }
    print("  processed exports: \(ledger.processedExports)")
    print("  conflicts: \(ledger.conflicts.map(\.id))")

case "steam-check", "steam-write-test":
    guard let lib = Paths.detectSteamworksLibrary() else { print("no libsteam_api.dylib found"); exit(1) }
    print("Using \(lib.path)")
    do {
        let s = try SteamCloudSession(library: lib)
        defer { s.close() }
        print("cloud enabled for account: \(s.cloudEnabledForAccount), for app: \(s.cloudEnabledForApp)")
        if let q = s.quotaBytes { print("quota: \(q.available)/\(q.total) bytes free") }
        let entries = s.list()
        print("\(entries.count) files in Steam Cloud for app \(darkestDungeonAppID):")
        for e in entries.sorted(by: { $0.name < $1.name }) { print("  \(e.name)  \(e.size) bytes  \(hr(e.timestamp))") }
        if command == "steam-write-test" {
            let name = "steam_init.json"
            let data = try s.read(name)
            print("read \(name): \(data.count) bytes; writing the same bytes back…")
            try s.write(name, data)
            let again = try s.read(name)
            print(again == data ? "write ok, contents unchanged" : "write returned different contents!")
        }
    } catch {
        print("failed: \(error)"); exit(1)
    }

case "steam-push":
    guard args.count >= 2 else { print("usage: stagecoach-cli steam-push profile_N [folder]"); exit(2) }
    let profile = args[args.startIndex + 1]
    guard let lib = Paths.detectSteamworksLibrary() else { print("no libsteam_api.dylib found"); exit(1) }
    let folder: URL
    if args.count >= 3 { folder = URL(fileURLWithPath: args[args.startIndex + 2], isDirectory: true) }
    else if let steam = Paths.detectSteamRemote() { folder = steam.appendingPathComponent(profile, isDirectory: true) }
    else { print("Steam save folder not found"); exit(1) }
    guard let snap = Snapshot.read(folder), !snap.isEmpty else { print("nothing to push in \(folder.path)"); exit(1) }
    guard !Processes.gameIsRunning else { print("Darkest Dungeon is running; quit it first"); exit(1) }
    do {
        let s = try SteamCloudSession(library: lib)
        defer { s.close() }
        for name in snap.files.keys.sorted() {
            let data = try Data(contentsOf: folder.appendingPathComponent(name))
            try s.write("\(profile)/\(name)", data)
            print("  wrote \(profile)/\(name) (\(data.count) bytes)")
        }
        s.close()
        SteamCloudSession.nudge(library: lib)
        print("pushed \(snap.files.count) files; Steam uploads them now")
    } catch { print("failed: \(error)"); exit(1) }

case "sync":
    let dropbox = Paths.detectDropboxAppFolder()
    let root = dropbox?.deletingLastPathComponent().deletingLastPathComponent()
    var config = SyncConfig(steamRemote: Paths.detectSteamRemote(), dropboxFolder: dropbox,
                            archiveFolder: root?.appendingPathComponent("Darkest Dungeon Save Sync/Imported exports", isDirectory: true),
                            backupsFolder: Paths.supportDir.appendingPathComponent("Backups", isDirectory: true),
                            steamworksLibrary: Paths.detectSteamworksLibrary())
    config.steamHelper = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let engine = SyncEngine(config: config)
    engine.log = { print("  \($0)") }
    engine.syncNow(reason: "cli")
    if !engine.status.waitingForDownload.isEmpty {
        print("waiting for an export to settle; running once more in \(Int(config.quietSeconds) + 1)s…")
        Thread.sleep(forTimeInterval: config.quietSeconds + 1)
        engine.syncNow(reason: "cli retry")
    }
    let st = engine.status
    for p in st.profiles { print("\(p.profile): Mac \(hr(p.macNewest)), iPad copy \(hr(p.mirrorNewest)), \(p.inStep ? "in step" : "not in step"), cloud \(p.record?.cloudState ?? "-")") }
    for c in st.conflicts { print("CONFLICT \(c.id): iPad \(hr(c.ipadNewest)) vs Mac \(hr(c.macNewest))") }
    if let e = st.lastError { print("error: \(e)") }

default:
    print("usage: stagecoach-cli scan | steam-check | steam-write-test | steam-push profile_N [folder] | sync")
    exit(2)
}
