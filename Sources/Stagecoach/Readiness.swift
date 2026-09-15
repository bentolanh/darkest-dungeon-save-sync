// Is a folder Dropbox handed us actually a save yet?
//
// Dropbox creates every file in a folder the moment it learns of it, at zero
// bytes, and fills them in afterwards. A folder of empty placeholders does not
// change while the download is pending, so waiting for it to stop changing is
// not enough: it looks settled the whole time. Importing one writes empty files
// over a real campaign.
//
// So a folder counts as a save only when every file in it is a save: non-empty,
// and readable as the format the game writes. A half-downloaded file fails on
// its own header, and an empty one fails at the first byte.

import Foundation

enum Readiness {
    enum Verdict: Equatable {
        case ready
        case empty(files: Int)            // still all placeholders
        case incomplete(file: String)     // arrived in part, or not a save
        case nothingThere

        var isReady: Bool { self == .ready }
        var describe: String {
            switch self {
            case .ready: return "ready"
            case .empty(let n): return "Dropbox has not downloaded it yet (\(n) empty file\(n == 1 ? "" : "s"))"
            case .incomplete(let f): return "\(f) is not a complete save file yet"
            case .nothingThere: return "no save files in it"
            }
        }
    }

    /// Asks the system to fetch a file a cloud provider is holding back. Returns
    /// when the fetch finishes or the wait runs out; either way the caller then
    /// judges the file on what is actually on disk.
    static func hydrate(_ url: URL, timeout: TimeInterval = 20) {
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            var err: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &err) { at in
                _ = try? Data(contentsOf: at)
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
    }

    /// Checks one profile folder. Only `.ready` may be imported.
    static func check(profileDir: URL) -> Verdict {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: profileDir.path) else { return .nothingThere }
        let saves = names.filter { !Snapshot.ignored($0) && $0.hasSuffix(".json") }.sorted()
        guard !saves.isEmpty else { return .nothingThere }

        // Dropbox can keep a file "online only": it exists at zero bytes with a
        // placeholder mark, and an ordinary read returns nothing. A coordinated
        // read is the request that makes the system fetch it.
        for name in saves {
            let url = profileDir.appendingPathComponent(name)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size == 0 { hydrate(url) }
        }

        var empties = 0
        for name in saves {
            let url = profileDir.appendingPathComponent(name)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size == 0 { empties += 1 }
        }
        if empties == saves.count { return .empty(files: empties) }
        if empties > 0 { return .incomplete(file: "\(empties) of \(saves.count) files are still empty") }

        for name in saves {
            guard let data = try? Data(contentsOf: profileDir.appendingPathComponent(name)),
                  (try? SaveFile(data)) != nil else {
                return .incomplete(file: name)
            }
        }
        return .ready
    }
}
