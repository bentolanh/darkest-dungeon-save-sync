// Reading and rewriting Darkest Dungeon's binary save files.
//
// A save is a 64-byte header, a table of objects, a table of fields, and a data
// section. The header records where each table starts and how big it is:
//
//     0  magic 01 B1 00 00        16  object-table size     44  field count
//     4  revision                 20  object count          48  field-table offset
//     8  header length (64)       24  object-table offset   56  data length
//                                                           60  data offset
//
// An object-table entry is four numbers: its parent object, the field that names
// it, how many fields sit directly inside it, and how many counting descendants.
// A field-table entry is three: a hash of the name, where the field starts within
// the data section, and a packed word — bit 0 says the field is an object, bits
// 2 to 10 the length of its name including the trailing zero, and the rest the
// object it refers to.
//
// In the data section each field is its name, a zero byte, then its value. The
// value's own layout depends on a type this file never records, so values are
// carried here as opaque bytes and written back exactly. That is enough to drop
// a whole object — everything a save needs stripping for — while leaving every
// other byte of the file untouched.

import Foundation

struct SaveFile {
    struct Object { var parent: Int; var nameField: Int; var direct: Int; var all: Int }
    struct Field {
        var hash: UInt32
        var name: String
        var isObject: Bool
        var object: Int        // index into `objects` when isObject
        var value: [UInt8]     // everything between the name's zero byte and the next field
    }

    var header: [UInt8]        // the original 64 bytes; offsets within are rewritten on output
    var objects: [Object]
    var fields: [Field]

    enum Failure: Error, CustomStringConvertible {
        case notASave, truncated
        var description: String {
            switch self {
            case .notASave: return "not a Darkest Dungeon save file"
            case .truncated: return "the save file is truncated or malformed"
            }
        }
    }

    // MARK: - Reading

    init(_ data: Data) throws {
        let b = [UInt8](data)
        guard b.count >= 64, b[0] == 0x01, b[1] == 0xB1, b[2] == 0, b[3] == 0 else { throw Failure.notASave }
        func u32(_ o: Int) throws -> Int {
            guard o + 4 <= b.count else { throw Failure.truncated }
            return Int(UInt32(b[o]) | UInt32(b[o+1]) << 8 | UInt32(b[o+2]) << 16 | UInt32(b[o+3]) << 24)
        }
        let objectCount = try u32(20), objectOffset = try u32(24)
        let fieldCount = try u32(44), fieldOffset = try u32(48)
        let dataLength = try u32(56), dataOffset = try u32(60)
        guard dataOffset + dataLength <= b.count else { throw Failure.truncated }

        header = Array(b[0..<64])
        objects = try (0..<objectCount).map { i in
            let o = objectOffset + i * 16
            return Object(parent: try u32(o), nameField: try u32(o + 4), direct: try u32(o + 8), all: try u32(o + 12))
        }
        fields = try (0..<fieldCount).map { i in
            let o = fieldOffset + i * 12
            let hash = UInt32(try u32(o))
            let start = dataOffset + (try u32(o + 4))
            let info = try u32(o + 8)
            let nameLength = (info >> 2) & 0x1FF
            let next = i + 1 < fieldCount ? dataOffset + (try u32(fieldOffset + (i + 1) * 12 + 4)) : dataOffset + dataLength
            guard nameLength >= 1, start + nameLength <= next, next <= b.count else { throw Failure.truncated }
            let name = String(bytes: b[start..<(start + nameLength - 1)], encoding: .utf8) ?? ""
            return Field(hash: hash, name: name, isObject: info & 1 == 1, object: info >> 11,
                         value: Array(b[(start + nameLength)..<next]))
        }
    }

    // MARK: - Writing

    func serialized() -> Data {
        var data: [UInt8] = [], offsets: [Int] = []
        for f in fields {
            offsets.append(data.count)
            data += Array(f.name.utf8); data.append(0); data += f.value
        }
        func p32(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)] }
        var objectTable: [UInt8] = []
        for o in objects { objectTable += p32(o.parent) + p32(o.nameField) + p32(o.direct) + p32(o.all) }
        var fieldTable: [UInt8] = []
        for (f, off) in zip(fields, offsets) {
            let info = (f.object << 11) | ((f.name.utf8.count + 1) & 0x1FF) << 2 | (f.isObject ? 1 : 0)
            fieldTable += p32(Int(f.hash)) + p32(off) + p32(info)
        }
        var out = header
        func put(_ o: Int, _ v: Int) { let p = p32(v); out[o] = p[0]; out[o+1] = p[1]; out[o+2] = p[2]; out[o+3] = p[3] }
        put(16, objectTable.count); put(20, objects.count); put(24, 64)
        put(44, fields.count); put(48, 64 + objectTable.count)
        put(56, data.count); put(60, 64 + objectTable.count + fieldTable.count)
        return Data(out + objectTable + fieldTable + data)
    }

    // MARK: - Editing

    /// The first object field with this name, or nil. A name on its own can be
    /// ambiguous — a save has two objects called "dlc", one listing the add-ons
    /// the campaign uses and one listing the adverts it has shown — so pass the
    /// enclosing object's name when it matters.
    func indexOfObject(named name: String, under parent: String? = nil) -> Int? {
        fields.indices.first { i in
            guard fields[i].isObject, fields[i].name == name, fields[i].object < objects.count else { return false }
            guard let parent else { return true }
            return nameOfObject(objects[fields[i].object].parent) == parent
        }
    }

    /// The name an object goes by, taken from the field that introduces it.
    func nameOfObject(_ index: Int) -> String? {
        guard index < objects.count, objects[index].nameField < fields.count else { return nil }
        return fields[objects[index].nameField].name
    }

    /// The names of the objects sitting directly inside a named object.
    func children(of name: String) -> [String] {
        guard let i = indexOfObject(named: name) else { return [] }
        let parent = fields[i].object
        return fields.filter { $0.isObject && $0.object < objects.count && objects[$0.object].parent == parent && $0.name != name }
            .map(\.name)
    }

    /// Removes an object and everything inside it, leaving the rest of the file
    /// byte-identical. Returns false when there is no such object.
    @discardableResult
    mutating func removeObject(named name: String, under parent: String? = nil) -> Bool {
        guard let field = indexOfObject(named: name, under: parent) else { return false }
        let object = fields[field].object
        guard object < objects.count else { return false }
        let fieldSpan = 1 + objects[object].all
        // A save whose tables disagree with each other is left alone rather than
        // half-edited: better to publish nothing than a damaged campaign.
        guard fieldSpan >= 1, field + fieldSpan <= fields.count,
              objects[object].parent < objects.count else { return false }

        // An object's descendants follow it contiguously in the object table.
        var objectSpan = 1
        var j = object + 1
        while j < objects.count, objects[j].parent >= object, objects[j].parent < object + objectSpan {
            objectSpan = j - object + 1; j += 1
        }
        guard object + objectSpan <= objects.count else { return false }

        let parent = objects[object].parent
        objects[parent].direct -= 1
        var ancestor: Int? = parent
        while let a = ancestor {
            objects[a].all -= fieldSpan
            ancestor = a == 0 ? nil : objects[a].parent
        }
        fields.removeSubrange(field..<(field + fieldSpan))
        objects.removeSubrange(object..<(object + objectSpan))

        for i in objects.indices {
            if objects[i].parent >= object + objectSpan { objects[i].parent -= objectSpan }
            if objects[i].nameField >= field + fieldSpan { objects[i].nameField -= fieldSpan }
        }
        for i in fields.indices where fields[i].isObject {
            if fields[i].object >= object + objectSpan { fields[i].object -= objectSpan }
        }
        return true
    }

    /// True when these raw bytes appear anywhere in the file's names or values.
    func mentions(_ needle: String) -> Bool {
        let n = Array(needle.utf8)
        if fields.contains(where: { $0.name.utf8.count >= n.count && Array($0.name.utf8).contains(n) }) { return true }
        return fields.contains { field in
            let v = field.value
            guard v.count >= n.count else { return false }
            for i in 0...(v.count - n.count) where Array(v[i..<i + n.count]) == n { return true }
            return false
        }
    }
}

private extension Array where Element == UInt8 {
    func contains(_ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, count >= needle.count else { return false }
        for i in 0...(count - needle.count) where Array(self[i..<i + needle.count]) == needle { return true }
        return false
    }
}
