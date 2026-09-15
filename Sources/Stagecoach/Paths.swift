// Where things live on this Mac: the Steam Cloud folder for Darkest Dungeon,
// the Dropbox app folder the iPad reads and writes, and a Steamworks library
// to talk to the Steam client with. Everything here is discovery; nothing is
// written.

import Foundation

let darkestDungeonAppID = "262060"

enum Paths {
    static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Stagecoach", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let steamRoot = home.appendingPathComponent("Library/Application Support/Steam", isDirectory: true)

    /// `userdata/<id>/262060/remote` — the folder Steam keeps in step with Steam Cloud.
    /// When several Steam accounts have used this Mac, the one with a Darkest
    /// Dungeon folder wins; several of those, and the most recently written wins.
    static func detectSteamRemote() -> URL? {
        let userdata = steamRoot.appendingPathComponent("userdata", isDirectory: true)
        guard let ids = try? FileManager.default.contentsOfDirectory(at: userdata, includingPropertiesForKeys: nil) else { return nil }
        var candidates: [(URL, Date)] = []
        for id in ids {
            let remote = id.appendingPathComponent("\(darkestDungeonAppID)/remote", isDirectory: true)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: remote.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let mtime = (try? remote.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            candidates.append((remote, mtime))
        }
        return candidates.max(by: { $0.1 < $1.1 })?.0
    }

    /// Dropbox's own record of where its folder is, falling back to the usual places.
    static func detectDropboxRoot() -> URL? {
        let info = home.appendingPathComponent(".dropbox/info.json")
        if let data = try? Data(contentsOf: info),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["personal", "business"] {
                if let acct = json[key] as? [String: Any], let path = acct["path"] as? String,
                   FileManager.default.fileExists(atPath: path) {
                    return URL(fileURLWithPath: path, isDirectory: true)
                }
            }
        }
        for candidate in [home.appendingPathComponent("Dropbox"),
                          home.appendingPathComponent("Library/CloudStorage/Dropbox")] {
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// `Apps/DarkestDungeon` inside Dropbox: the folder the iPad game exports to and imports from.
    static func detectDropboxAppFolder() -> URL? {
        guard let root = detectDropboxRoot() else { return nil }
        let folder = root.appendingPathComponent("Apps/DarkestDungeon", isDirectory: true)
        return FileManager.default.fileExists(atPath: folder.path) ? folder : nil
    }

    /// Every Steam library folder registered on this Mac (the main one plus any on external drives).
    static func steamLibraries() -> [URL] {
        var libs = [steamRoot]
        let vdf = steamRoot.appendingPathComponent("steamapps/libraryfolders.vdf")
        if let text = try? String(contentsOf: vdf, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "\"").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                if parts.count >= 2, parts[0] == "path" {
                    let url = URL(fileURLWithPath: parts[1], isDirectory: true)
                    if !libs.contains(url) { libs.append(url) }
                }
            }
        }
        return libs.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// A Steamworks runtime (`libsteam_api.dylib`) we can load to talk to the Steam client.
    /// Preference order: one the user dropped into our support folder, then the newest
    /// copy shipped inside a game in the main Steam library, then games in other
    /// libraries (external drives). Nothing is loaded here — the file's own header
    /// says whether it carries a slice for this Mac; loading a library can block on a
    /// system prompt, so that happens only when a cloud session is opened.
    static func detectSteamworksLibrary() -> URL? {
        let own = supportDir.appendingPathComponent("libsteam_api.dylib")
        if FileManager.default.fileExists(atPath: own.path), hasNativeSlice(own) { return own }
        let fm = FileManager.default
        for lib in steamLibraries() {
            var found: [(URL, Date)] = []
            let common = lib.appendingPathComponent("steamapps/common", isDirectory: true)
            guard let games = try? fm.contentsOfDirectory(at: common, includingPropertiesForKeys: nil) else { continue }
            for game in games {
                guard let e = fm.enumerator(at: game, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
                for case let url as URL in e {
                    if e.level > 6 { e.skipDescendants(); continue }
                    if url.lastPathComponent == "libsteam_api.dylib", hasNativeSlice(url) {
                        let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                        found.append((url, m))
                    }
                }
            }
            if let best = found.max(by: { $0.1 < $1.1 })?.0 { return best }
        }
        return nil
    }

    /// Reads the Mach-O header: true if the file is, or contains, a slice for this CPU.
    static func hasNativeSlice(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url), let data = try? h.read(upToCount: 4096), data.count >= 8 else { return false }
        #if arch(arm64)
        let want: UInt32 = 0x0100000C   // CPU_TYPE_ARM64
        #else
        let want: UInt32 = 0x01000007   // CPU_TYPE_X86_64
        #endif
        let magic = data.withUnsafeBytes { $0.load(as: UInt32.self) }
        switch magic {
        case 0xFEEDFACF:                 // thin 64-bit, little-endian
            return data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) } == want
        case 0xBEBAFECA:                 // fat, big-endian header ("CAFEBABE" read little-endian)
            let count = Int(UInt32(bigEndian: data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }))
            for i in 0..<min(count, 16) {
                let off = 8 + i * 20
                guard off + 4 <= data.count else { break }
                let cpu = UInt32(bigEndian: data.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt32.self) })
                if cpu == want { return true }
            }
            return false
        default:
            return false
        }
    }
}
