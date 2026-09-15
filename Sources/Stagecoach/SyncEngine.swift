// The sync itself. Two places hold a Darkest Dungeon save on this Mac:
//
//   Steam side   userdata/<id>/262060/remote/profile_N        what the Mac game plays,
//                                                              and what Steam Cloud mirrors
//   Dropbox side Apps/DarkestDungeon/profile_N                 what the iPad's Import lists
//                Apps/DarkestDungeon/<date>_<time>_upload/     what the iPad's Export drops
//
// Inbound: a new export folder appears → its profiles go into the Steam side
// (through the Steam client when it's running, so the cloud copy updates at
// once), the Dropbox root is refreshed to match, and the export folder is
// moved out of Apps/DarkestDungeon because the iPad's Import hangs if one is
// left there.
//
// Outbound: the Mac game saves → once the burst is over, the Steam side is
// copied to Apps/DarkestDungeon/profile_N, ready for Import on the iPad.
//
// The ledger's digest per profile is the last state both sides agreed on. If
// an export arrives and the Steam side has moved on since that state, both
// have new progress and the app asks instead of guessing.

import Foundation

struct SyncConfig {
    var steamRemote: URL?
    var dropboxFolder: URL?
    var archiveFolder: URL?
    var backupsFolder: URL
    var steamworksLibrary: URL?
    var steamHelper: URL?              // stagecoach-cli; the push runs there so the process can exit
    var archiveExports = true
    var cloudPush = true
    var quietSeconds: TimeInterval = 5
    var gameIsRunning: () -> Bool = { Processes.gameIsRunning }
    var steamIsRunning: () -> Bool = { Processes.steamIsRunning }
    var now: () -> Date = { Date() }
}

struct ProfileStatus: Identifiable, Equatable {
    var id: String { profile }
    var profile: String
    var macNewest: Date?
    var mirrorNewest: Date?
    var inStep: Bool
    var record: ProfileRecord?
}

struct SyncStatus: Equatable {
    var profiles: [ProfileStatus] = []
    var conflicts: [Conflict] = []
    var waitingForDownload: [String] = []
    var exportsStuck: [String] = []          // consumed exports still inside Apps/DarkestDungeon
    var waitingForGameToQuit = false
    var lastTick: Date?
    var lastError: String?
}

final class SyncEngine {
    var config: SyncConfig
    private(set) var ledger: Ledger
    private let ledgerURL: URL
    private let queue = DispatchQueue(label: "stagecoach.engine")
    private var stability: [String: (signature: String, since: Date)] = [:]
    private var pendingRetry: DispatchWorkItem?

    var log: (String) -> Void = { print($0) }
    var notify: (String, String) -> Void = { _, _ in }
    var statusChanged: (SyncStatus) -> Void = { _ in }
    private(set) var status = SyncStatus()

    init(config: SyncConfig, ledgerURL: URL = Ledger.url) {
        self.config = config
        self.ledgerURL = ledgerURL
        self.ledger = Ledger.load(from: ledgerURL)
    }

    // MARK: - Entry points

    func sync(reason: String) {
        queue.async { self.tick(reason: reason) }
    }

    func syncNow(reason: String) {
        queue.sync { self.tick(reason: reason) }
    }

    func resolve(conflict id: String, keep: String) {
        queue.async {
            self.ledger.resolutions[id] = keep
            self.ledger.conflicts.removeAll { $0.id == id }
            self.ledger.save(to: self.ledgerURL)
            self.tick(reason: "conflict resolved: keep \(keep)")
        }
    }

    // MARK: - One pass

    private func tick(reason: String) {
        pendingRetry?.cancel()
        var st = SyncStatus(lastTick: config.now())
        defer {
            st.conflicts = ledger.conflicts
            st.exportsStuck = archiveFailures
            status = st
            statusChanged(st)
        }
        guard let steam = config.steamRemote, let dropbox = config.dropboxFolder else {
            st.lastError = "Steam save folder or Dropbox folder not found"
            return
        }
        let gameRunning = config.gameIsRunning()
        var needRetry = false

        // 1. Inbound: export folders the iPad dropped, oldest first.
        let exports = ((try? FileManager.default.contentsOfDirectory(atPath: dropbox.path)) ?? [])
            .filter(isExportFolder).sorted()
        for name in exports {
            let folder = dropbox.appendingPathComponent(name, isDirectory: true)
            if ledger.processedExports.contains(name) {
                archiveIfWanted(folder)
                continue
            }
            guard isStable(folder) else {
                st.waitingForDownload.append(name)
                needRetry = true
                break
            }
            var done = true
            for profile in profileFolders(in: folder) {
                let source = folder.appendingPathComponent(profile, isDirectory: true)
                guard let ipad = Snapshot.read(source), !ipad.isEmpty else { continue }
                let target = steam.appendingPathComponent(profile, isDirectory: true)
                let mac = Snapshot.read(target)
                let conflictID = "\(name)/\(profile)"
                let record = ledger.profiles[profile]

                if let mac, mac.digest == ipad.digest {
                    log("\(name)/\(profile): already identical to the Mac save")
                    ledger.conflicts.removeAll { $0.id == conflictID }
                    continue
                }

                // Does the Mac hold progress this export can't contain? Yes if the
                // Mac's save changed since the two sides were last in step, or if the
                // export is older than the save the Mac already held at that point.
                let macMovedOn: Bool
                let exportTime = ipad.newestModified ?? .distantPast
                if let mac, !mac.isEmpty {
                    if let record {
                        macMovedOn = mac.digest != record.syncedDigest
                            || exportTime < (record.syncedSaveTime ?? .distantPast)
                    } else {
                        // Never synced before: the newer save is the one to keep.
                        macMovedOn = (mac.newestModified ?? .distantPast) > exportTime
                    }
                } else {
                    macMovedOn = false
                }

                let keep: String
                if !macMovedOn {
                    keep = "ipad"
                } else if let choice = ledger.resolutions[conflictID] {
                    keep = choice
                } else if record == nil {
                    keep = "mac"
                    log("\(name)/\(profile): first sync and the Mac save is newer, keeping the Mac save")
                    notify("Older iPad export set aside", "\(profile): the Mac save is newer than the export \(name), so the Mac save was kept. The export is in the archive.")
                } else {
                    if !ledger.conflicts.contains(where: { $0.id == conflictID }) {
                        let c = Conflict(profile: profile, exportFolder: name, macNewest: mac?.newestModified,
                                         ipadNewest: ipad.newestModified, detectedAt: config.now())
                        ledger.conflicts.append(c)
                        log("\(name)/\(profile): both the iPad and the Mac have new progress — waiting for you to choose")
                        notify("Which save should win?", "\(profile): the iPad export and the Mac save both changed. Open Stagecoach to choose.")
                    }
                    done = false
                    continue
                }

                if keep == "ipad" {
                    if gameRunning {
                        log("\(name)/\(profile): the game is running, will import once it quits")
                        st.waitingForGameToQuit = true
                        done = false
                        continue
                    }
                    do {
                        let cloudState = try importToSteam(profile: profile, from: source, snapshot: ipad, target: target, existing: mac)
                        try writeMirror(profile: profile, from: source, snapshot: ipad, dropbox: dropbox)
                        ledger.profiles[profile] = ProfileRecord(syncedDigest: ipad.digest, syncedSaveTime: Snapshot.read(target)?.newestModified,
                                                                 syncedAt: config.now(), lastSource: "ipad", cloudState: cloudState)
                        log("\(name)/\(profile): imported into Steam (\(cloudState == "uploaded" ? "pushed to Steam Cloud" : "Steam Cloud will pick it up when the game next launches"))")
                        notify("iPad save imported", "\(profile) is now on Steam" + (cloudState == "uploaded" ? " and in Steam Cloud." : "; Steam Cloud updates at the next launch."))
                    } catch {
                        log("\(name)/\(profile): import failed: \(error)")
                        st.lastError = "\(profile): \(error)"
                        done = false
                        continue
                    }
                } else {
                    log("\(name)/\(profile): keeping the Mac save; the iPad export goes to the archive")
                }
                ledger.conflicts.removeAll { $0.id == conflictID }
                ledger.resolutions.removeValue(forKey: conflictID)
            }
            if done {
                ledger.processedExports.append(name)
                archiveIfWanted(folder)
            } else {
                break
            }
        }

        // 2. Outbound: the Mac's saves, mirrored to the Dropbox root for the iPad's Import.
        // A profile with an export still waiting (downloading, or blocked on a choice)
        // is left alone, so the ledger keeps saying what the Mac last agreed on.
        let pendingProfiles = Set(exports.filter { !ledger.processedExports.contains($0) }
            .flatMap { profileFolders(in: dropbox.appendingPathComponent($0, isDirectory: true)) })
        for profile in profileFolders(in: steam) {
            let target = steam.appendingPathComponent(profile, isDirectory: true)
            guard let mac = Snapshot.read(target), !mac.isEmpty else { continue }
            let mirrorURL = dropbox.appendingPathComponent(profile, isDirectory: true)
            let mirror = Snapshot.read(mirrorURL)
            var ps = ProfileStatus(profile: profile, macNewest: mac.newestModified, mirrorNewest: mirror?.newestModified,
                                   inStep: mirror?.digest == mac.digest, record: ledger.profiles[profile])
            defer { st.profiles.append(ps) }

            if pendingProfiles.contains(profile) { continue }
            if mirror?.digest == mac.digest {
                if ledger.profiles[profile] == nil {
                    ledger.profiles[profile] = ProfileRecord(syncedDigest: mac.digest, syncedSaveTime: mac.newestModified,
                                                             syncedAt: config.now(), lastSource: "mac", cloudState: "uploaded")
                    ps.record = ledger.profiles[profile]
                }
                continue
            }
            if let newest = mac.newestModified, config.now().timeIntervalSince(newest) < config.quietSeconds {
                needRetry = true
                continue
            }
            do {
                try writeMirror(profile: profile, from: target, snapshot: mac, dropbox: dropbox)
                ledger.profiles[profile] = ProfileRecord(syncedDigest: mac.digest, syncedSaveTime: mac.newestModified,
                                                         syncedAt: config.now(), lastSource: "mac", cloudState: "uploaded")
                ps.record = ledger.profiles[profile]
                ps.inStep = true
                ps.mirrorNewest = Snapshot.read(mirrorURL)?.newestModified
                log("\(profile): Mac save copied to Dropbox for the iPad")
            } catch {
                log("\(profile): could not copy to Dropbox: \(error)")
                st.lastError = "\(profile): \(error)"
            }
        }

        ledger.save(to: ledgerURL)
        if needRetry {
            let item = DispatchWorkItem { [weak self] in self?.tick(reason: "retry") }
            pendingRetry = item
            queue.asyncAfter(deadline: .now() + config.quietSeconds + 1, execute: item)
        }
    }

    // MARK: - Pieces

    /// True once an export folder has looked the same for a whole quiet period —
    /// Dropbox lands its files one at a time.
    private func isStable(_ folder: URL) -> Bool {
        var parts: [String] = []
        if let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) {
            for case let url as URL in e {
                let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                parts.append("\(url.lastPathComponent):\(v?.fileSize ?? -1):\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)")
            }
        }
        let signature = parts.sorted().joined(separator: "|")
        let now = config.now()
        if let seen = stability[folder.path], seen.signature == signature {
            return now.timeIntervalSince(seen.since) >= config.quietSeconds
        }
        stability[folder.path] = (signature, now)
        return false
    }

    /// Puts an iPad profile onto the Steam side. Returns the cloud state reached.
    private func importToSteam(profile: String, from source: URL, snapshot: Snapshot, target: URL, existing: Snapshot?) throws -> String {
        if let existing, !existing.isEmpty {
            try backUp(profile: profile, from: target)
        }
        var cloudState = "pendingGameLaunch"
        if config.cloudPush, let lib = config.steamworksLibrary, config.steamIsRunning() {
            do {
                try pushToCloud(profile: profile, folder: source, snapshot: snapshot, library: lib)
                // The client uploads on the next "game launch": one more short session,
                // started after it has noticed the first one ending, is that launch.
                // Its own record (remotecache.vdf) then says whether the upload went through.
                Thread.sleep(forTimeInterval: 3)
                let before = waitForUpload(profile: profile, names: Array(snapshot.files.keys), seconds: 0).count
                nudgeCloud(library: lib)
                let pending = waitForUpload(profile: profile, names: Array(snapshot.files.keys), seconds: 15)
                log("\(profile): Steam marked \(before) file(s) pending before the nudge, \(pending.count) after (\(config.steamHelper == nil ? "in-process" : "helper"))")
                if pending.isEmpty {
                    cloudState = "uploaded"
                } else {
                    log("\(profile): written through Steam, but \(pending.count) file(s) still show as pending upload; Steam finishes them on its own or at the next launch")
                    cloudState = "pendingUpload"
                }
            } catch {
                log("\(profile): Steam Cloud push failed (\(error)); copying the files instead")
            }
        }
        // Whether or not the client wrote them for us, make sure the local files match.
        if Snapshot.read(target)?.digest != snapshot.digest {
            try copyFiles(from: source, snapshot: snapshot, to: target, pruneExtras: false)
        }
        return cloudState
    }

    private func pushToCloud(profile: String, folder: URL, snapshot: Snapshot, library: URL) throws {
        if let helper = config.steamHelper {
            let p = Process()
            p.executableURL = helper
            p.arguments = ["steam-push", profile, folder.path]
            let out = Pipe(); p.standardOutput = out; p.standardError = out
            try p.run()
            p.waitUntilExit()
            let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            log("\(profile): helper pid \(p.processIdentifier) exited \(p.terminationStatus): \(text.split(separator: "\n").last.map(String.init) ?? "")")
            guard p.terminationStatus == 0 else {
                throw SteamCloudError.writeFailed(text.split(separator: "\n").last.map(String.init) ?? "helper failed")
            }
        } else {
            let session = try SteamCloudSession(library: library)
            defer { session.close() }
            for name in snapshot.files.keys.sorted() {
                try session.write("\(profile)/\(name)", try Data(contentsOf: folder.appendingPathComponent(name)))
            }
        }
    }

    private func nudgeCloud(library: URL) {
        if let helper = config.steamHelper {
            let p = Process(); p.executableURL = helper; p.arguments = ["steam-check"]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
        } else {
            SteamCloudSession.nudge(library: library)
        }
    }

    /// Polls Steam's remotecache.vdf until none of the profile's files is marked pending.
    private func waitForUpload(profile: String, names: [String], seconds: TimeInterval) -> [String] {
        guard let steam = config.steamRemote else { return [] }
        let cache = steam.deletingLastPathComponent().appendingPathComponent("remotecache.vdf")
        let deadline = Date().addingTimeInterval(seconds)
        var pending: [String] = []
        repeat {
            pending = SteamCache.pendingFiles(in: cache).filter { names.contains($0.replacingOccurrences(of: "\(profile)/", with: "")) && $0.hasPrefix("\(profile)/") }
            if pending.isEmpty { return [] }
            Thread.sleep(forTimeInterval: 1)
        } while Date() < deadline
        return pending
    }

    private func writeMirror(profile: String, from source: URL, snapshot: Snapshot, dropbox: URL) throws {
        let mirror = dropbox.appendingPathComponent(profile, isDirectory: true)
        try copyFiles(from: source, snapshot: snapshot, to: mirror, pruneExtras: true)
    }

    /// Overwrites each file in place. No temporary names, no renames, no deletes:
    /// on the Dropbox side any file removed or moved makes Dropbox stop and ask
    /// the user, and a rename over the old file counts as removing it.
    private func copyFiles(from source: URL, snapshot: Snapshot, to dest: URL, pruneExtras: Bool) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        for name in snapshot.files.keys.sorted() {
            let data = try Data(contentsOf: source.appendingPathComponent(name))
            let target = dest.appendingPathComponent(name)
            if let existing = try? Data(contentsOf: target), existing == data { continue }
            try data.write(to: target)
        }
        if pruneExtras, let existing = try? fm.contentsOfDirectory(atPath: dest.path) {
            for name in existing where !Snapshot.ignored(name) && snapshot.files[name] == nil {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: dest.appendingPathComponent(name).path, isDirectory: &isDir), !isDir.boolValue {
                    try? fm.removeItem(at: dest.appendingPathComponent(name))
                }
            }
        }
    }

    private func backUp(profile: String, from target: URL) throws {
        let fm = FileManager.default
        let stamp = Self.stampFormatter.string(from: config.now())
        let dest = config.backupsFolder.appendingPathComponent("\(stamp)/\(profile)", isDirectory: true)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: target, to: dest)
        // Keep the thirty newest backups.
        if let all = try? fm.contentsOfDirectory(atPath: config.backupsFolder.path) {
            for old in all.filter({ !$0.hasPrefix(".") }).sorted().dropLast(30) {
                try? fm.removeItem(at: config.backupsFolder.appendingPathComponent(old))
            }
        }
    }

    /// Exports that couldn't be moved out (Dropbox asks the user to confirm a move
    /// out of the app folder; a cancelled dialog fails the move). Not retried until
    /// the user asks, so the dialog doesn't come back every half minute.
    private(set) var archiveFailures: [String] = []

    func retryArchive() {
        queue.async {
            self.archiveFailures.removeAll()
            self.tick(reason: "retry moving exports")
        }
    }

    private func archiveIfWanted(_ folder: URL) {
        guard config.archiveExports, let archive = config.archiveFolder else { return }
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.path) else { return }
        guard !archiveFailures.contains(folder.lastPathComponent) else { return }
        do {
            try fm.createDirectory(at: archive, withIntermediateDirectories: true)
            var dest = archive.appendingPathComponent(folder.lastPathComponent)
            var n = 2
            while fm.fileExists(atPath: dest.path) {
                dest = archive.appendingPathComponent("\(folder.lastPathComponent) (\(n))"); n += 1
            }
            try fm.moveItem(at: folder, to: dest)
            log("\(folder.lastPathComponent): moved out of Apps/DarkestDungeon so the iPad's Import keeps working")
        } catch {
            archiveFailures.append(folder.lastPathComponent)
            log("\(folder.lastPathComponent): could not move it out of Apps/DarkestDungeon (\(error.localizedDescription)); the iPad's Import will hang until it's moved")
        }
    }

    static let stampFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd_HHmmss"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
}
