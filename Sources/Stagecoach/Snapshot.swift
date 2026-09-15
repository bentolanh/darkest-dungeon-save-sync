// A snapshot is what one profile folder contains right now: each save file's
// bytes summarised by a hash, and the whole folder summarised by one digest.
// Two folders with the same digest hold the same save. The game's own
// `backup/` subfolder is ignored, as are Finder and Dropbox housekeeping files.

import CryptoKit
import Foundation

struct FileState: Equatable {
    let size: Int
    let modified: Date
    let sha256: String
}

struct Snapshot: Equatable {
    let files: [String: FileState]   // relative name → state

    var isEmpty: Bool { files.isEmpty }
    var newestModified: Date? { files.values.map(\.modified).max() }

    /// One hash for the whole folder, over sorted "name:sha" lines.
    var digest: String {
        var h = SHA256()
        for name in files.keys.sorted() {
            h.update(data: Data("\(name):\(files[name]!.sha256)\n".utf8))
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func ignored(_ name: String) -> Bool {
        name.hasPrefix(".") || name == "Icon\r" || name.hasSuffix(".tmp") || name.hasPrefix("~")
    }

    /// Reads a profile folder. Returns nil when the folder doesn't exist; an
    /// existing but empty folder is an empty snapshot.
    static func read(_ dir: URL) -> Snapshot? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]) else { return nil }
        var files: [String: FileState] = [:]
        for url in entries {
            let name = url.lastPathComponent
            if ignored(name) { continue }
            guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                  v.isRegularFile == true else { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            files[name] = FileState(size: v.fileSize ?? data.count, modified: v.contentModificationDate ?? .distantPast, sha256: sha)
        }
        return Snapshot(files: files)
    }
}

/// Names of the campaign-slot folders the game uses: profile_0 … profile_N.
func profileFolders(in dir: URL) -> [String] {
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
    return entries.filter { $0.hasPrefix("profile_") && Int($0.dropFirst("profile_".count)) != nil }
        .sorted { (Int($0.dropFirst(8)) ?? 0) < (Int($1.dropFirst(8)) ?? 0) }
}

/// Folders the iPad's Export creates: `20260811_153851_upload`.
func isExportFolder(_ name: String) -> Bool {
    let parts = name.split(separator: "_")
    return parts.count == 3 && parts[2] == "upload" && parts[0].count == 8 && parts[1].count == 6
        && parts[0].allSatisfy(\.isNumber) && parts[1].allSatisfy(\.isNumber)
}
