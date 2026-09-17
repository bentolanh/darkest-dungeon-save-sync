// What the window shows and what the buttons do. Owns the engine, the folder
// watchers, the settings, and the rolling log.

import AppKit
import Combine
import Foundation
import ServiceManagement
import UserNotifications

@MainActor
final class Model: ObservableObject {
    @Published var status = SyncStatus()
    @Published var logLines: [String] = []
    @Published var steamRunning = false
    @Published var gameRunning = false

    @Published var steamRemote: URL?
    @Published var dropboxFolder: URL?
    @Published var steamworksLibrary: URL?

    @Published var archiveExports: Bool { didSet { defaults.set(archiveExports, forKey: "archiveExports"); rebuild() } }
    @Published var cloudPush: Bool { didSet { defaults.set(cloudPush, forKey: "cloudPush"); rebuild() } }
    @Published var startSteamForPush: Bool { didSet { defaults.set(startSteamForPush, forKey: "startSteamForPush"); rebuild() } }
    @Published var launchAtLogin: Bool { didSet { setLaunchAtLogin(launchAtLogin) } }

    private let defaults = UserDefaults.standard
    private var engine: SyncEngine?
    private var watcher: FolderWatcher?
    private var timer: Timer?
    private let logURL = Paths.supportDir.appendingPathComponent("log.txt")

    init() {
        archiveExports = defaults.object(forKey: "archiveExports") as? Bool ?? true
        cloudPush = defaults.object(forKey: "cloudPush") as? Bool ?? true
        startSteamForPush = defaults.object(forKey: "startSteamForPush") as? Bool ?? false
        launchAtLogin = SMAppService.mainApp.status == .enabled
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        rebuild()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshProcesses(); self?.engine?.sync(reason: "timer") }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            // Steam starting is the moment a campaign that was waiting for it can
            // finally be put into the cloud.
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == "com.valvesoftware.steam" else { return }
            Task { @MainActor in
                self?.refreshProcesses()
                self?.engine?.sync(reason: "Steam started")
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.refreshProcesses()
                self?.engine?.sync(reason: "an app quit")
            }
        }
    }

    // MARK: Settings

    func override(_ key: String) -> URL? {
        defaults.string(forKey: key).map { URL(fileURLWithPath: $0) }
    }

    func setOverride(_ key: String, _ url: URL?) {
        if let url { defaults.set(url.path, forKey: key) } else { defaults.removeObject(forKey: key) }
        rebuild()
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            append("Launch at login: \(error.localizedDescription)")
        }
    }

    // MARK: Engine

    func rebuild() {
        let overrides = (steam: override("steamRemote"), dropbox: override("dropboxFolder"), lib: override("steamworksLibrary"))
        DispatchQueue.global(qos: .utility).async {
            let steam = overrides.steam ?? Paths.detectSteamRemote()
            let dropbox = overrides.dropbox ?? Paths.detectDropboxAppFolder()
            let lib = overrides.lib ?? Paths.detectSteamworksLibrary()
            Task { @MainActor in self.wire(steamRemote: steam, dropboxFolder: dropbox, steamworksLibrary: lib) }
        }
    }

    private func wire(steamRemote: URL?, dropboxFolder: URL?, steamworksLibrary: URL?) {
        self.steamRemote = steamRemote
        self.dropboxFolder = dropboxFolder
        self.steamworksLibrary = steamworksLibrary
        let dropboxRoot = dropboxFolder?.deletingLastPathComponent().deletingLastPathComponent()
        var config = SyncConfig(steamRemote: steamRemote, dropboxFolder: dropboxFolder,
                                archiveFolder: dropboxRoot?.appendingPathComponent("Darkest Dungeon Save Sync/Imported exports", isDirectory: true),
                                backupsFolder: Paths.supportDir.appendingPathComponent("Backups", isDirectory: true),
                                steamworksLibrary: steamworksLibrary)
        config.archiveExports = archiveExports
        config.cloudPush = cloudPush
        config.startSteamForPush = startSteamForPush
        config.steamHelper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/stagecoach-cli")
        if !FileManager.default.isExecutableFile(atPath: config.steamHelper!.path) { config.steamHelper = nil }
        let engine = SyncEngine(config: config)
        engine.log = { [weak self] line in Task { @MainActor in self?.append(line) } }
        engine.notify = { title, body in
            let content = UNMutableNotificationContent()
            content.title = title; content.body = body; content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
        engine.statusChanged = { [weak self] st in Task { @MainActor in self?.status = st } }
        self.engine = engine
        watcher = FolderWatcher(paths: [steamRemote, dropboxFolder].compactMap { $0 }) { [weak engine] in
            engine?.sync(reason: "folder changed")
        }
        refreshProcesses()
        engine.sync(reason: "start")
    }

    func syncNow() { refreshProcesses(); engine?.sync(reason: "sync now") }

    func resolve(_ c: Conflict, keep: String) { engine?.resolve(conflict: c.id, keep: keep) }

    func decide(_ o: Orphan, choice: String) { engine?.decide(orphan: o.profile, choice: choice) }

    func retryArchive() { engine?.retryArchive() }

    func refreshProcesses() {
        steamRunning = Processes.steamIsRunning
        gameRunning = Processes.gameIsRunning
    }

    var backupsFolder: URL { Paths.supportDir.appendingPathComponent("Backups", isDirectory: true) }

    private func append(_ line: String) {
        let stamp = Self.timeFormatter.string(from: Date())
        let entry = "\(stamp)  \(line)"
        logLines.append(entry)
        if logLines.count > 300 { logLines.removeFirst(logLines.count - 300) }
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write(Data((entry + "\n").utf8)); try? h.close()
        } else {
            try? Data((entry + "\n").utf8).write(to: logURL)
        }
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()
}
