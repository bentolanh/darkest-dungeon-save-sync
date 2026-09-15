// Talking to the Steam client through the Steamworks "flat" C API, loaded at
// run time from a libsteam_api.dylib. Initialising as app 262060 lets this
// process write into Darkest Dungeon's Steam Cloud storage the same way the
// game does: the client copies the file into userdata/.../remote and uploads
// it straight away, so nothing waits for the next game launch.
//
// While a session is open Steam shows the account as playing Darkest Dungeon,
// so sessions are kept short: open, write, close.

import Foundation

enum SteamCloudError: Error, CustomStringConvertible {
    case libraryMissing
    case symbolMissing(String)
    case initFailed(String)
    case writeFailed(String)
    case readFailed(String)

    var description: String {
        switch self {
        case .libraryMissing: return "no libsteam_api.dylib found"
        case .symbolMissing(let s): return "libsteam_api.dylib has no \(s)"
        case .initFailed(let s): return "Steam refused the session: \(s)"
        case .writeFailed(let s): return "Steam Cloud refused to write \(s)"
        case .readFailed(let s): return "Steam Cloud could not read \(s)"
        }
    }
}

final class SteamCloudSession {
    private typealias InitFlat = @convention(c) (UnsafeMutablePointer<CChar>?) -> Int32
    private typealias InitSafe = @convention(c) () -> Bool
    private typealias Void0 = @convention(c) () -> Void
    private typealias Accessor = @convention(c) () -> OpaquePointer?
    private typealias FileWrite = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafeRawPointer?, Int32) -> Bool
    private typealias FileRead = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?, Int32) -> Int32
    private typealias FileNameFn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Bool
    private typealias FileSize = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Int32
    private typealias FileTimestamp = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Int64
    private typealias FileCount = @convention(c) (OpaquePointer?) -> Int32
    private typealias FileNameAndSize = @convention(c) (OpaquePointer?, Int32, UnsafeMutablePointer<Int32>?) -> UnsafePointer<CChar>?
    private typealias BoolFn = @convention(c) (OpaquePointer?) -> Bool
    private typealias Quota = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UInt64>?, UnsafeMutablePointer<UInt64>?) -> Bool

    private let handle: UnsafeMutableRawPointer
    private let storage: OpaquePointer
    private let shutdown: Void0
    private let runCallbacks: Void0
    private let fileWrite: FileWrite
    private let fileRead: FileRead
    private let fileExists: FileNameFn
    private let fileDelete: FileNameFn
    private let fileSize: FileSize
    private let fileTimestamp: FileTimestamp?
    private let fileCount: FileCount
    private let fileNameAndSize: FileNameAndSize
    private let cloudForAccount: BoolFn
    private let cloudForApp: BoolFn
    private let quota: Quota
    private var closed = false

    struct Entry { let name: String; let size: Int; let timestamp: Date? }

    /// Opens a session with the Steam client as Darkest Dungeon. Fails when Steam
    /// isn't running, the account doesn't own the game, or the library is unusable.
    init(library: URL) throws {
        // libsteam_api learns which game it is from the environment (or a
        // steam_appid.txt beside the executable, which we don't want to ship).
        setenv("SteamAppId", darkestDungeonAppID, 1)
        setenv("SteamGameId", darkestDungeonAppID, 1)
        guard let h = dlopen(library.path, RTLD_NOW | RTLD_LOCAL) else {
            let msg = dlerror().map { String(cString: $0) } ?? "dlopen failed"
            throw SteamCloudError.initFailed(msg)
        }
        handle = h
        func sym<T>(_ name: String, as: T.Type) throws -> T {
            guard let p = dlsym(h, name) else { throw SteamCloudError.symbolMissing(name) }
            return unsafeBitCast(p, to: T.self)
        }
        shutdown = try sym("SteamAPI_Shutdown", as: Void0.self)
        runCallbacks = try sym("SteamAPI_RunCallbacks", as: Void0.self)

        if let p = dlsym(h, "SteamAPI_InitFlat") {
            let initFlat = unsafeBitCast(p, to: InitFlat.self)
            var msg = [CChar](repeating: 0, count: 1024)
            let result = msg.withUnsafeMutableBufferPointer { initFlat($0.baseAddress) }
            if result != 0 {
                dlclose(h)
                throw SteamCloudError.initFailed(String(cString: msg) + " (code \(result))")
            }
        } else {
            let initSafe = try sym("SteamAPI_InitSafe", as: InitSafe.self)
            if !initSafe() { dlclose(h); throw SteamCloudError.initFailed("SteamAPI_InitSafe returned false; is Steam running and signed in?") }
        }

        let accessor = try sym("SteamAPI_SteamRemoteStorage_v016", as: Accessor.self)
        guard let s = accessor() else { shutdown(); dlclose(h); throw SteamCloudError.initFailed("no ISteamRemoteStorage interface") }
        storage = s
        fileWrite = try sym("SteamAPI_ISteamRemoteStorage_FileWrite", as: FileWrite.self)
        fileRead = try sym("SteamAPI_ISteamRemoteStorage_FileRead", as: FileRead.self)
        fileExists = try sym("SteamAPI_ISteamRemoteStorage_FileExists", as: FileNameFn.self)
        fileDelete = try sym("SteamAPI_ISteamRemoteStorage_FileDelete", as: FileNameFn.self)
        fileSize = try sym("SteamAPI_ISteamRemoteStorage_GetFileSize", as: FileSize.self)
        fileTimestamp = dlsym(h, "SteamAPI_ISteamRemoteStorage_GetFileTimestamp").map { unsafeBitCast($0, to: FileTimestamp.self) }
        fileCount = try sym("SteamAPI_ISteamRemoteStorage_GetFileCount", as: FileCount.self)
        fileNameAndSize = try sym("SteamAPI_ISteamRemoteStorage_GetFileNameAndSize", as: FileNameAndSize.self)
        cloudForAccount = try sym("SteamAPI_ISteamRemoteStorage_IsCloudEnabledForAccount", as: BoolFn.self)
        cloudForApp = try sym("SteamAPI_ISteamRemoteStorage_IsCloudEnabledForApp", as: BoolFn.self)
        quota = try sym("SteamAPI_ISteamRemoteStorage_GetQuota", as: Quota.self)
    }

    deinit { close() }

    /// Ends the session. Pending uploads are handed to the client during a short
    /// callbacks loop first; the client finishes them on its own afterwards.
    func close() {
        guard !closed else { return }
        closed = true
        let until = Date().addingTimeInterval(2)
        while Date() < until { runCallbacks(); Thread.sleep(forTimeInterval: 0.1) }
        shutdown()
        dlclose(handle)
    }

    /// Opening and closing one more short session makes the client flush whatever
    /// the previous one left queued (observed: files stay "pending" until then).
    static func nudge(library: URL) {
        Thread.sleep(forTimeInterval: 1)
        if let s = try? SteamCloudSession(library: library) { s.close() }
    }

    var cloudEnabledForAccount: Bool { cloudForAccount(storage) }
    var cloudEnabledForApp: Bool { cloudForApp(storage) }

    var quotaBytes: (total: UInt64, available: UInt64)? {
        var t: UInt64 = 0, a: UInt64 = 0
        return quota(storage, &t, &a) ? (t, a) : nil
    }

    func list() -> [Entry] {
        var out: [Entry] = []
        for i in 0..<fileCount(storage) {
            var size: Int32 = 0
            guard let c = fileNameAndSize(storage, i, &size) else { continue }
            let name = String(cString: c)
            let ts = fileTimestamp.map { Date(timeIntervalSince1970: TimeInterval($0(storage, name))) }
            out.append(Entry(name: name, size: Int(size), timestamp: ts))
        }
        return out
    }

    func exists(_ name: String) -> Bool { fileExists(storage, name) }

    func read(_ name: String) throws -> Data {
        let size = fileSize(storage, name)
        guard size >= 0 else { throw SteamCloudError.readFailed(name) }
        var data = Data(count: Int(size))
        let got = data.withUnsafeMutableBytes { fileRead(storage, name, $0.baseAddress, size) }
        guard got == size else { throw SteamCloudError.readFailed(name) }
        return data
    }

    /// Writes one file into the game's cloud storage; the client mirrors it into
    /// the local remote folder and queues the upload.
    func write(_ name: String, _ data: Data) throws {
        let ok = data.withUnsafeBytes { fileWrite(storage, name, $0.baseAddress, Int32(data.count)) }
        guard ok else { throw SteamCloudError.writeFailed(name) }
        runCallbacks()
    }

    func delete(_ name: String) -> Bool { fileDelete(storage, name) }
}
