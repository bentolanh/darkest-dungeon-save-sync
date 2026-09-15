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
    var publishIncompatible = false   // publish a Mac save the iPad can't load anyway
    var clearAddOnList = false        // when preparing, also clear the campaign's add-on list
    var matchIPadBuild = false        // when preparing, down-convert to the build the iPad writes
    var quietSeconds: TimeInterval = 5
    var gameIsRunning: () -> Bool = { Processes.gameIsRunning }
    var steamIsRunning: () -> Bool = { Processes.steamIsRunning }
    var now: () -> Date = { Date() }
}

struct ProfileStatus: Identifiable, Equatable {
    var id: String { profile }
    var profile: String
    var estate: String?
    var issues: [CompatibilityIssue] = []
    var preparedForIPad = false
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
    var heldBack: [ProfileStatus] = []       // Mac saves not published: the iPad would crash on them
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
    private var warnedIncompatible: Set<String> = []
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
            st.heldBack = st.profiles.filter { !$0.issues.isEmpty && !config.publishIncompatible && !$0.preparedForIPad }
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
            let unready = profileFolders(in: folder)
                .map { ($0, Readiness.check(profileDir: folder.appendingPathComponent($0, isDirectory: true))) }
                .filter { !$0.1.isReady }
            if !unready.isEmpty {
                for (slot, verdict) in unready {
                    log("\(name)/\(slot): waiting — \(verdict.describe)")
                }
                st.waitingForDownload.append(name)
                needRetry = true
                break
            }
            var done = true
            for (sourceProfile, profile) in routes(for: folder, steam: steam) {
                let source = folder.appendingPathComponent(sourceProfile, isDirectory: true)
                guard let ipad = Snapshot.read(source), !ipad.isEmpty else { continue }

                // Never write a half-arrived folder over a campaign. Dropbox puts
                // every file in place at zero bytes before it downloads any of
                // them, and a folder of placeholders sits perfectly still.
                let readiness = Readiness.check(profileDir: source)
                guard readiness.isReady else {
                    log("\(name)/\(sourceProfile): not importing — \(readiness.describe)")
                    if !st.waitingForDownload.contains(name) { st.waitingForDownload.append(name) }
                    needRetry = true
                    done = false
                    continue
                }
                let target = steam.appendingPathComponent(profile, isDirectory: true)
                let mac = Snapshot.read(target)
                let conflictID = "\(name)/\(sourceProfile)"
                let record = ledger.profiles[profile]
                let estate = CampaignInfo.read(profileDir: source).estate
                let label = "\(name)/\(sourceProfile)" + (estate.map { " (\($0))" } ?? "") + " → \(profile)"

                if let mac, mac.digest == ipad.digest {
                    log("\(label): already identical to the Mac save")
                    ledger.conflicts.removeAll { $0.id == conflictID }
                    continue
                }

                // Does the Mac hold progress this export can't contain? Yes if the
                // Mac's save changed since the two sides were last in step, or if the
                // export is older than the save the Mac already held at that point.
                let macMovedOn: Bool
                let exportTime = saveTime(of: source, snapshot: ipad) ?? .distantPast
                if let mac, !mac.isEmpty {
                    if let record {
                        macMovedOn = mac.digest != record.syncedDigest
                            || exportTime < (record.syncedSaveTime ?? .distantPast)
                    } else {
                        // Never synced before: the newer save is the one to keep.
                        macMovedOn = (saveTime(of: target, snapshot: mac) ?? .distantPast) > exportTime
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
                    log("\(label): first sync and the Mac save is newer, keeping the Mac save")
                    notify("Older iPad export set aside", "\(estate ?? profile): the Mac save is newer than the export \(name), so the Mac save was kept. The export is in the archive.")
                } else {
                    if !ledger.conflicts.contains(where: { $0.id == conflictID }) {
                        let c = Conflict(profile: profile, exportFolder: name, estate: estate, macNewest: saveTime(of: target, snapshot: mac),
                                         ipadNewest: exportTime, detectedAt: config.now(), sourceProfile: sourceProfile)
                        ledger.conflicts.append(c)
                        log("\(label): both the iPad and the Mac have new progress — waiting for you to choose")
                        notify("Which save should win?", "\(estate ?? profile): the iPad export and the Mac save both changed. Open Stagecoach to choose.")
                    }
                    done = false
                    continue
                }

                if keep == "ipad" {
                    if gameRunning {
                        log("\(label): the game is running, will import once it quits")
                        st.waitingForGameToQuit = true
                        done = false
                        continue
                    }
                    do {
                        let cloudState = try importToSteam(profile: profile, from: source, snapshot: ipad, target: target, existing: mac)
                        try writeMirror(profile: profile, from: source, snapshot: ipad, dropbox: dropbox)
                        ledger.profiles[profile] = ProfileRecord(syncedDigest: ipad.digest, syncedSaveTime: saveTime(of: target, snapshot: Snapshot.read(target)),
                                                                 syncedAt: config.now(), lastSource: "ipad", cloudState: cloudState)
                        log("\(label): imported into Steam (\(cloudState == "uploaded" ? "pushed to Steam Cloud" : "Steam Cloud will pick it up when the game next launches"))")
                        notify("iPad save imported", "\(estate ?? profile) is now on Steam" + (cloudState == "uploaded" ? " and in Steam Cloud." : "; Steam Cloud updates at the next launch."))
                    } catch {
                        log("\(label): import failed: \(error)")
                        st.lastError = "\(profile): \(error)"
                        done = false
                        continue
                    }
                } else {
                    log("\(label): keeping the Mac save; the iPad export goes to the archive")
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
            .flatMap { routes(for: dropbox.appendingPathComponent($0, isDirectory: true), steam: steam).map(\.target) })
        for profile in profileFolders(in: steam) {
            let target = steam.appendingPathComponent(profile, isDirectory: true)
            guard let mac = Snapshot.read(target), !mac.isEmpty else { continue }
            let mirrorURL = dropbox.appendingPathComponent(profile, isDirectory: true)
            let mirror = Snapshot.read(mirrorURL)
            var ps = ProfileStatus(profile: profile, estate: CampaignInfo.read(profileDir: target).estate,
                                   macNewest: saveTime(of: target, snapshot: mac), mirrorNewest: mirror?.newestModified,
                                   inStep: mirror?.digest == mac.digest, record: ledger.profiles[profile])
            defer { st.profiles.append(ps) }

            if pendingProfiles.contains(profile) { continue }

            // A save carrying content the iPad cannot load is not published: the
            // iPad would list the campaign and then crash opening it.
            ps.issues = Compatibility.check(profileDir: target)
            ps.preparedForIPad = ledger.preparedForIPad[profile] == mac.digest
            if ledger.preparedForIPad[profile] != nil, ledger.preparedForIPad[profile] != mac.digest {
                ledger.preparedForIPad.removeValue(forKey: profile)
                log("\(ps.estate ?? profile): played since the copy for the iPad was made, so that copy is out of date")
            }
            if !ps.issues.isEmpty, !config.publishIncompatible, !ps.preparedForIPad {
                if mirror?.digest != mac.digest, !warnedIncompatible.contains(profile) {
                    warnedIncompatible.insert(profile)
                    let what = ps.issues.map(\.marker).joined(separator: ", ")
                    log("\(ps.estate ?? profile): not published for the iPad — \(ps.issues[0].explanation) (found: \(what))")
                    notify("This campaign can't go to the iPad", "\(ps.estate ?? profile): \(ps.issues[0].explanation)")
                }
                continue
            }
            warnedIncompatible.remove(profile)

            if ps.preparedForIPad {
                ps.inStep = true
                continue
            }
            if mirror?.digest == mac.digest {
                if ledger.profiles[profile] == nil {
                    ledger.profiles[profile] = ProfileRecord(syncedDigest: mac.digest, syncedSaveTime: saveTime(of: target, snapshot: mac),
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
                ledger.profiles[profile] = ProfileRecord(syncedDigest: mac.digest, syncedSaveTime: saveTime(of: target, snapshot: mac),
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

    /// Which slot in an export goes to which Steam slot. The iPad puts every
    /// imported campaign into a free slot and old copies are left behind, so an
    /// export can hold the same estate several times: the newest copy of each
    /// estate wins, and it goes to the Steam slot carrying that estate name. An
    /// estate the Mac doesn't have gets the first free slot; a copy whose name
    /// can't be read keeps its own slot number.
    func routes(for export: URL, steam: URL) -> [(source: String, target: String)] {
        var steamEstates: [String: String] = [:]      // estate → Steam slot
        for slot in profileFolders(in: steam) {
            if let e = CampaignInfo.read(profileDir: steam.appendingPathComponent(slot)).estate, steamEstates[e] == nil {
                steamEstates[e] = slot
            }
        }
        var newestByEstate: [String: (slot: String, time: Date)] = [:]
        var unnamed: [String] = []
        for slot in profileFolders(in: export) {
            let dir = export.appendingPathComponent(slot, isDirectory: true)
            let info = CampaignInfo.read(profileDir: dir)
            guard let estate = info.estate else { unnamed.append(slot); continue }
            let t = info.savedAt ?? Snapshot.read(dir)?.newestModified ?? .distantPast
            if let have = newestByEstate[estate] {
                let loser = t > have.time ? have.slot : slot
                log("\(export.lastPathComponent)/\(loser): older copy of \(estate), skipped")
            }
            if newestByEstate[estate] == nil || t > newestByEstate[estate]!.time { newestByEstate[estate] = (slot, t) }
        }
        var taken = Set(profileFolders(in: steam))
        var out: [(String, String)] = []
        for slot in unnamed { out.append((slot, slot)); taken.insert(slot) }
        for (estate, entry) in newestByEstate.sorted(by: { $0.value.slot < $1.value.slot }) {
            if let target = steamEstates[estate] {
                out.append((entry.slot, target))
            } else {
                let free = (0..<9).map { "profile_\($0)" }.first { !taken.contains($0) } ?? entry.slot
                taken.insert(free)
                log("\(export.lastPathComponent)/\(entry.slot): \(estate) is new to the Mac, it goes to \(free)")
                out.append((entry.slot, free))
            }
        }
        return out.sorted { $0.0 < $1.0 }
    }

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

    /// Publish Mac saves even when the iPad cannot load them (the user's call).
    func setPublishIncompatible(_ on: Bool) {
        queue.async {
            self.config.publishIncompatible = on
            self.warnedIncompatible.removeAll()
            self.tick(reason: on ? "publishing incompatible saves" : "holding incompatible saves")
        }
    }

    /// Publishes a cleaned copy of one Mac campaign for the iPad to import.
    /// Runs only when asked; nothing here happens on its own.
    func prepareForIPad(profile: String, completion: @escaping (Result<SanitiseReport, Error>) -> Void) {
        queue.async {
            guard let steam = self.config.steamRemote, let dropbox = self.config.dropboxFolder else {
                completion(.failure(SaveFile.Failure.notASave)); return
            }
            let source = steam.appendingPathComponent(profile, isDirectory: true)
            guard let snap = Snapshot.read(source), !snap.isEmpty else {
                completion(.failure(SaveFile.Failure.notASave)); return
            }
            do {
                let report = try Sanitise.copy(profile: profile, from: source,
                                               to: dropbox.appendingPathComponent(profile, isDirectory: true), snapshot: snap,
                                               clearAddOnList: self.config.clearAddOnList,
                                               matchIPadBuild: self.config.matchIPadBuild)
                self.ledger.preparedForIPad[profile] = snap.digest
                self.ledger.profiles[profile] = ProfileRecord(syncedDigest: snap.digest,
                                                              syncedSaveTime: saveTime(of: source, snapshot: snap),
                                                              syncedAt: self.config.now(), lastSource: "mac",
                                                              cloudState: self.ledger.profiles[profile]?.cloudState ?? "uploaded")
                self.ledger.save(to: self.ledgerURL)
                self.log("\(report.estate ?? profile): a copy without \(report.removed.joined(separator: " and ")) is now in Dropbox for the iPad")
                completion(.success(report))
                self.tick(reason: "prepared a campaign for the iPad")
            } catch {
                self.log("\(profile): could not prepare a copy for the iPad: \(error)")
                completion(.failure(error))
            }
        }
    }

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
