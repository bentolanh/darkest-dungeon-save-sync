// What a campaign calls itself. Darkest Dungeon's saves are binary JSON; the
// two fields we want sit in persist.game.json as a null-terminated field name,
// padding to a four-byte boundary, an int32 length, then the string:
//
//     "estatename\0" 04 00 00 00 "Sal\0"
//     "date_time\0" 00 14 00 00 00 "2026-08-24 17:09:07\0"
//
// The estate name is how a campaign is recognised across devices, since the
// iPad drops each imported campaign into whatever slot is free. The save time
// is the game's own clock for that campaign, steadier than file dates.

import Foundation

struct CampaignInfo: Equatable {
    var estate: String?
    var savedAt: Date?

    static func read(profileDir: URL) -> CampaignInfo {
        guard let data = try? Data(contentsOf: profileDir.appendingPathComponent("persist.game.json")) else { return CampaignInfo() }
        var info = CampaignInfo()
        info.estate = string(after: "estatename", in: data)
        if let s = string(after: "date_time", in: data) { info.savedAt = formatter.date(from: s) }
        return info
    }

    static func string(after field: String, in data: Data) -> String? {
        let key = Array((field + "\0").utf8)
        let bytes = [UInt8](data)
        guard bytes.count > key.count + 8 else { return nil }
        var i = 0
        while i + key.count + 5 <= bytes.count {
            if bytes[i] == key[0], Array(bytes[i..<i + key.count]) == key {
                var p = i + key.count
                while p % 4 != 0 && p < bytes.count && bytes[p] == 0 { p += 1 }
                guard p + 4 <= bytes.count else { return nil }
                let len = Int(bytes[p]) | Int(bytes[p + 1]) << 8 | Int(bytes[p + 2]) << 16 | Int(bytes[p + 3]) << 24
                guard len >= 1, len <= 256, p + 4 + len <= bytes.count, bytes[p + 4 + len - 1] == 0 else { return nil }
                return String(bytes: bytes[(p + 4)..<(p + 4 + len - 1)], encoding: .utf8)
            }
            i += 1
        }
        return nil
    }

    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()
}

/// The game's own save time when the file says so, else the newest file date.
func saveTime(of dir: URL, snapshot: Snapshot?) -> Date? {
    CampaignInfo.read(profileDir: dir).savedAt ?? snapshot?.newestModified
}
