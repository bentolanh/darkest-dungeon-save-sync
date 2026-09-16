// Has Dropbox finished with the files we wrote?
//
// Writing a copy into the Dropbox folder is not the same as the iPad being able
// to fetch it. Until Dropbox has uploaded the file, an Import on the iPad sees
// nothing there, or worse sees part of it — which is the same trouble in reverse
// as an export arriving here before Dropbox has downloaded it.
//
// Dropbox gives no API for this, but it does leave a mark: once it has taken a
// file in hand it attaches `com.dropbox.attrs` to it. A file freshly written by
// something else does not have it, and gains it within a few seconds. That is
// the only signal available, so that is the one used — and it is used only to
// say "ready" or "still going", never to hold anything back.

import Foundation

enum DropboxState {
    static let uploadedMark = "com.dropbox.attrs"

    /// True when Dropbox has taken this file in hand.
    static func isUploaded(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return getxattr(path, uploadedMark, nil, 0, 0, XATTR_NOFOLLOW) >= 0
        }
    }

    /// True when every save file in a published campaign has been taken in hand.
    /// A campaign that is not there at all is not waiting for anything.
    static func isUploaded(profileDir: URL) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: profileDir.path) else { return false }
        let saves = names.filter { $0.hasSuffix(".json") && !Snapshot.ignored($0) }
        guard !saves.isEmpty else { return false }
        return saves.allSatisfy { isUploaded(profileDir.appendingPathComponent($0)) }
    }
}
