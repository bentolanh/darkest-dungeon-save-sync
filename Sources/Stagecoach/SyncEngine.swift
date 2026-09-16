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
    var estate: String?
    var missingAddOns: [String] = []     // add-ons this campaign needs that the iPad has not got
    var weeks: Int?
    var uploaded = false                 // Dropbox has taken the published copy in hand
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
    var iPadLastExported: Date?              // when the iPad last sent anything at all
    var lastTick: Date?
    var lastError: String?
}

final class SyncEngine {
    var config: SyncConfig
    private(set) var ledger: Ledger
    private let ledgerURL: URL
    private let queue = DispatchQueue(label: "stagecoach.engine")
    private var stability: [String: (signature: String, since: Date)] = [:]
    private var reportedMissingAddOns: Set<String> = []
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
        // What the iPad has switched on, learned from the newest campaign it has
        // exported. Without one, nothing is assumed.
        let iPadAddOns = newestIPadAddOns(dropbox: dropbox)
        st.iPadLastExported = newestExportTime(dropbox: dropbox)
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
                // Does the Mac hold progress this export cannot contain?
                //
                // Once the two sides have agreed on a state, this is answerable:
                // the Mac has moved on if its save differs from what was agreed, or
                // if the export predates it. Before that first agreement there is
                // nothing to compare against, and a timestamp will not stand in for
                // one — opening a campaign on the iPad and leaving again makes it
                // the newer save while the Mac may hold months more play. So the
                // first meeting of two campaigns that differ is always asked about.
                let macMovedOn: Bool
                let firstMeeting: Bool
                let exportTime = saveTime(of: source, snapshot: ipad) ?? .distantPast
                if let mac, !mac.isEmpty {
                    if let record {
                        macMovedOn = mac.digest != record.syncedDigest
                            || exportTime < (record.syncedSaveTime ?? .distantPast)
                        firstMeeting = false
                    } else {
                        // No agreement to compare against, but weeks played says
                        // which campaign is further on without having to ask.
                        macMovedOn = furtherOn((weeksPlayed(of: target), inDungeon(target), saveTime(of: target, snapshot: mac)),
                                               than: (weeksPlayed(of: source), inDungeon(source), exportTime))
                        firstMeeting = true
                    }
                } else {
                    macMovedOn = false
                    firstMeeting = false
                }

                let keep: String
                if !macMovedOn {
                    keep = "ipad"
                } else if let choice = ledger.resolutions[conflictID] {
                    keep = choice
                } else if firstMeeting {
                    keep = "mac"
                    func where_(_ dir: URL) -> String {
                        let w = weeksPlayed(of: dir).map { "week \($0)" } ?? "an unknown week"
                        return (inDungeon(dir) == true) ? "\(w), out on an expedition" : w
                    }
                    let mw = where_(target), iw = where_(source)
                    log("\(label): the Mac is at \(mw) and the export at \(iw), so the Mac save is kept")
                    notify("The iPad's copy is behind", "\(estate ?? profile): the Mac is at \(mw), the iPad at \(iw). The Mac save was kept and the export is in the archive.")
                } else {
                    if !ledger.conflicts.contains(where: { $0.id == conflictID }) {
                        let c = Conflict(profile: profile, exportFolder: name, estate: estate,
                                         macNewest: saveTime(of: target, snapshot: mac),
                                         ipadNewest: exportTime, detectedAt: config.now(),
                                         sourceProfile: sourceProfile, firstMeeting: firstMeeting)
                        ledger.conflicts.append(c)
                        let why = firstMeeting
                            ? "these two campaigns have never been synced, so which is further on is yours to say"
                            : "both the iPad and the Mac have new progress"
                        log("\(label): \(why) — waiting for you to choose")
                        notify("Which save should win?",
                               firstMeeting
                               ? "\(estate ?? profile): the Mac and the iPad each hold a copy and they have never been synced. Open Stagecoach to choose."
                               : "\(estate ?? profile): the iPad export and the Mac save both changed. Open Stagecoach to choose.")
                    }
                    done = false
                    continue
                }

                // The iPad can offer to strip a campaign's add-on content for good.
                // A save that comes back that way must not quietly replace one on
                // the Mac that still has it.
                if keep == "ipad", let mac, !mac.isEmpty {
                    let macHas = Compatibility.addOnBelongings(profileDir: target)
                    let ipadHas = Compatibility.addOnBelongings(profileDir: source)
                    let lost = macHas.subtracting(ipadHas)
                    if !lost.isEmpty, ledger.resolutions[conflictID] == nil {
                        if !ledger.conflicts.contains(where: { $0.id == conflictID }) {
                            ledger.conflicts.append(Conflict(profile: profile, exportFolder: name, estate: estate,
                                                             macNewest: saveTime(of: target, snapshot: mac),
                                                             ipadNewest: exportTime, detectedAt: config.now(),
                                                             sourceProfile: sourceProfile))
                            log("\(label): the iPad copy has had its add-on content stripped (\(lost.sorted().joined(separator: ", ")) is gone); waiting for you to choose")
                            notify("The iPad copy lost add-on content", "\(estate ?? profile): importing it would drop \(lost.sorted().joined(separator: ", ")) from the Mac save too.")
                        }
                        done = false
                        continue
                    }
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
                        // What now stands in Dropbox came from the iPad and needs no
                        // editing, so the outbound pass must not treat it as unpublished
                        // and overwrite the record of where this campaign came from.
                        ledger.publishedFrom[profile] = Snapshot.read(target)?.digest ?? ipad.digest
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
                                   weeks: weeksPlayed(of: target),
                                   macNewest: saveTime(of: target, snapshot: mac), mirrorNewest: mirror?.newestModified,
                                   inStep: mirror?.digest == mac.digest, record: ledger.profiles[profile])
            defer { st.profiles.append(ps) }

            if pendingProfiles.contains(profile) { continue }

            ps.missingAddOns = Compatibility.missingAddOns(profileDir: target, iPadHas: iPadAddOns)

            // Said once, and then the campaign goes out anyway. A campaign asking
            // for add-ons the iPad has not got still opens there: the game offers
            // to take that content out, and does.
            if !ps.missingAddOns.isEmpty, !reportedMissingAddOns.contains(profile) {
                reportedMissingAddOns.insert(profile)
                let names = ps.missingAddOns.map(Compatibility.readable).joined(separator: " and ")
                log("\(ps.estate ?? profile): uses \(names), which the iPad has not got — it will offer to take that content out, and cannot put it back")
            }

            // A published copy is not the Mac save byte for byte: two small edits
            // make it open on the iPad. So what was published is remembered by the
            // state of the campaign it came from, rather than by comparing the two.
            ps.inStep = ledger.publishedFrom[profile] == mac.digest && mirror != nil
            if ps.inStep {
                // Written is not the same as uploaded. Until Dropbox has taken the
                // files in hand, an Import on the iPad has nothing to fetch.
                ps.uploaded = DropboxState.isUploaded(profileDir: mirrorURL)
                if !ps.uploaded { needRetry = true }
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
                let report = try Sanitise.copy(profile: profile, from: target,
                                               to: dropbox.appendingPathComponent(profile, isDirectory: true),
                                               snapshot: mac)
                ledger.publishedFrom[profile] = mac.digest
                ledger.profiles[profile] = ProfileRecord(syncedDigest: mac.digest, syncedSaveTime: saveTime(of: target, snapshot: mac),
                                                         syncedAt: config.now(), lastSource: "mac", cloudState: "uploaded")
                ps.record = ledger.profiles[profile]
                ps.inStep = true
                ps.uploaded = DropboxState.isUploaded(profileDir: dropbox.appendingPathComponent(profile, isDirectory: true))
                if !ps.uploaded { needRetry = true }
                ps.mirrorNewest = Snapshot.read(mirrorURL)?.newestModified
                let what = report.removed.isEmpty ? "" : " (\(report.removed.joined(separator: "; ")))"
                log("\(ps.estate ?? profile): copied to Dropbox for the iPad\(what)")
            } catch {
                log("\(ps.estate ?? profile): could not copy to Dropbox: \(error)")
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

    /// When the iPad last exported anything, read from the names of the export
    /// folders it writes. Nothing else on this Mac knows what is on the iPad, so
    /// this is the only honest answer to "how long since it was heard from".
    func newestExportTime(dropbox: URL) -> Date? {
        var names: [String] = []
        for root in [dropbox, config.archiveFolder].compactMap({ $0 }) {
            names += ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter(isExportFolder)
        }
        guard let newest = names.max() else { return nil }
        return SyncEngine.stampFormatter.date(from: String(newest.dropLast("_upload".count)))
    }

    /// The add-ons the iPad has switched on, learned from the campaign it is
    /// actually playing.
    ///
    /// An export holds every campaign on the iPad, and that includes copies sent
    /// from this Mac which came back unopened — one of those asks for six add-ons
    /// the iPad has not got, and reading it would have the tool believe the iPad
    /// has them all. The campaign to trust is the one most recently saved by the
    /// game itself, since the iPad can only have saved a campaign it could open.
    func newestIPadAddOns(dropbox: URL) -> Set<String>? {
        var best: (when: Date, addOns: Set<String>)?
        for root in [dropbox, config.archiveFolder].compactMap({ $0 }) {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter(isExportFolder)
            for name in names {
                let folder = root.appendingPathComponent(name, isDirectory: true)
                for slot in profileFolders(in: folder) {
                    let dir = folder.appendingPathComponent(slot, isDirectory: true)
                    let list = Sanitise.addOns(in: dir.appendingPathComponent("persist.game.json"))
                    guard !list.isEmpty, let when = CampaignInfo.read(profileDir: dir).savedAt else { continue }
                    if best == nil || when > best!.when { best = (when, Set(list)) }
                }
            }
        }
        return best?.addOns
    }

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
        var newestByEstate: [String: (slot: String, time: Date, weeks: Int?, inDungeon: Bool?)] = [:]
        var unnamed: [String] = []
        for slot in profileFolders(in: export) {
            let dir = export.appendingPathComponent(slot, isDirectory: true)
            let info = CampaignInfo.read(profileDir: dir)
            guard let estate = info.estate else { unnamed.append(slot); continue }
            let t = info.savedAt ?? Snapshot.read(dir)?.newestModified ?? .distantPast
            let w = weeksPlayed(of: dir)
            let raid = inDungeon(dir)
            if let have = newestByEstate[estate] {
                let loser = furtherOn((w, raid, t), than: (have.weeks, have.inDungeon, have.time)) ? have.slot : slot
                log("\(export.lastPathComponent)/\(loser): a copy of \(estate) that is not as far on, skipped")
            }
            if newestByEstate[estate] == nil
                || furtherOn((w, raid, t), than: (newestByEstate[estate]!.weeks, newestByEstate[estate]!.inDungeon, newestByEstate[estate]!.time)) {
                newestByEstate[estate] = (slot, t, w, raid)
            }
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
