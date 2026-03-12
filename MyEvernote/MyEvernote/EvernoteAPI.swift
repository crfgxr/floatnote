import Foundation

// MARK: - Models

struct Notebook: Identifiable, Codable {
    let guid: String
    let name: String
    let stack: String?
    var id: String { guid }
}

struct NoteMeta: Identifiable, Codable {
    let guid: String
    let title: String
    let created: Int64
    let updated: Int64
    let notebookGuid: String
    var id: String { guid }

    var updatedDate: Date { Date(timeIntervalSince1970: Double(updated) / 1000) }
    var createdDate: Date { Date(timeIntervalSince1970: Double(created) / 1000) }
}

struct NoteContent {
    let guid: String
    let title: String
    let content: String
    let created: Int64
    let updated: Int64
}

// MARK: - Thrift Binary Protocol Helpers

class ThriftWriter {
    var data = Data()

    func writeByte(_ val: UInt8) { data.append(val) }

    func writeI16(_ val: Int16) {
        var v = val.bigEndian
        data.append(Data(bytes: &v, count: 2))
    }

    func writeI32(_ val: Int32) {
        var v = val.bigEndian
        data.append(Data(bytes: &v, count: 4))
    }

    func writeString(_ val: String) {
        let bytes = Array(val.utf8)
        writeI32(Int32(bytes.count))
        data.append(contentsOf: bytes)
    }

    func writeBool(_ val: Bool) { writeByte(val ? 1 : 0) }

    func writeMessageBegin(_ name: String, type: UInt8, seqId: Int32) {
        let version: Int32 = Int32(bitPattern: 0x80010000) | Int32(type)
        writeI32(version)
        writeString(name)
        writeI32(seqId)
    }

    func writeFieldBegin(type: UInt8, id: Int16) {
        writeByte(type)
        writeI16(id)
    }

    func writeFieldStop() { writeByte(0) }

    func writeStructBegin() {}
    func writeStructEnd() { writeFieldStop() }
}

class ThriftReader {
    let data: Data
    var offset: Int = 0

    init(_ data: Data) { self.data = data }

    var remaining: Int { data.count - offset }

    func readByte() -> UInt8 {
        guard offset < data.count else { return 0 }
        let val = data[offset]
        offset += 1
        return val
    }

    func readI16() -> Int16 {
        guard offset + 2 <= data.count else { return 0 }
        let val = data.subdata(in: offset..<offset+2).withUnsafeBytes { $0.load(as: Int16.self) }
        offset += 2
        return Int16(bigEndian: val)
    }

    func readI32() -> Int32 {
        guard offset + 4 <= data.count else { return 0 }
        let val = data.subdata(in: offset..<offset+4).withUnsafeBytes { $0.load(as: Int32.self) }
        offset += 4
        return Int32(bigEndian: val)
    }

    func readI64() -> Int64 {
        guard offset + 8 <= data.count else { return 0 }
        let val = data.subdata(in: offset..<offset+8).withUnsafeBytes { $0.load(as: Int64.self) }
        offset += 8
        return Int64(bigEndian: val)
    }

    func readString() -> String {
        let len = Int(readI32())
        guard len > 0, offset + len <= data.count else { return "" }
        let str = String(data: data.subdata(in: offset..<offset+len), encoding: .utf8) ?? ""
        offset += len
        return str
    }

    func readBool() -> Bool { readByte() != 0 }

    func readBinary() -> Data {
        let len = Int(readI32())
        guard len > 0, offset + len <= data.count else { return Data() }
        let d = data.subdata(in: offset..<offset+len)
        offset += len
        return d
    }

    func readMessageBegin() -> (name: String, type: UInt8, seqId: Int32) {
        let version = readI32()
        let type = UInt8(version & 0xFF)
        let name = readString()
        let seqId = readI32()
        return (name, type, seqId)
    }

    func readFieldBegin() -> (type: UInt8, id: Int16) {
        guard remaining > 0 else { return (0, 0) }
        let type = readByte()
        if type == 0 { return (0, 0) } // STOP
        guard remaining >= 2 else { return (0, 0) }
        let id = readI16()
        return (type, id)
    }

    func skipField(type: UInt8) {
        guard remaining > 0 else { return }
        switch type {
        case 2: _ = readByte() // BOOL
        case 3: _ = readByte() // BYTE
        case 6: _ = readI16() // I16
        case 8: _ = readI32() // I32
        case 10: _ = readI64() // I64
        case 4: // DOUBLE
            guard remaining >= 8 else { return }
            offset += 8
        case 11: _ = readString() // STRING
        case 12: // STRUCT
            while remaining > 0 {
                let f = readFieldBegin()
                if f.type == 0 { break }
                skipField(type: f.type)
            }
        case 13: // MAP
            let kt = readByte(); let vt = readByte(); let count = readI32()
            for _ in 0..<max(0, count) { guard remaining > 0 else { return }; skipField(type: kt); skipField(type: vt) }
        case 14: // SET
            let et = readByte(); let count = readI32()
            for _ in 0..<max(0, count) { guard remaining > 0 else { return }; skipField(type: et) }
        case 15: // LIST
            let et = readByte(); let count = readI32()
            for _ in 0..<max(0, count) { guard remaining > 0 else { return }; skipField(type: et) }
        default: break
        }
    }
}

// MARK: - Thrift Type Constants
let T_BOOL: UInt8 = 2
let T_BYTE: UInt8 = 3
let T_I16: UInt8 = 6
let T_I32: UInt8 = 8
let T_I64: UInt8 = 10
let T_STRING: UInt8 = 11
let T_STRUCT: UInt8 = 12
let T_LIST: UInt8 = 15

// MARK: - Evernote API

class EvernoteAPI: ObservableObject {
    private var token: String
    private let noteStoreUrl: String
    private var seqId: Int32 = 0

    init(token: String, shard: String) {
        self.token = token
        self.noteStoreUrl = "https://www.evernote.com/shard/\(shard)/notestore"
    }

    private func nextSeqId() -> Int32 {
        seqId += 1
        return seqId
    }

    private func call(_ data: Data) async throws -> Data {
        var request = URLRequest(url: URL(string: noteStoreUrl)!)
        request.httpMethod = "POST"
        request.setValue("application/x-thrift", forHTTPHeaderField: "Content-Type")
        request.setValue("application/x-thrift", forHTTPHeaderField: "Accept")
        request.httpBody = data
        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return responseData
    }

    // MARK: - listNotebooks

    func listNotebooks() async throws -> [Notebook] {
        let w = ThriftWriter()
        w.writeMessageBegin("listNotebooks", type: 1, seqId: nextSeqId())
        // arg 1: authenticationToken (string, field 1)
        w.writeFieldBegin(type: T_STRING, id: 1)
        w.writeString(token)
        w.writeFieldStop()

        let resp = try await call(w.data)
        let r = ThriftReader(resp)
        _ = r.readMessageBegin()

        var notebooks: [Notebook] = []
        let field = r.readFieldBegin()
        if field.type == T_LIST {
            let _ = r.readByte()
            let count = r.readI32()
            for _ in 0..<count {
                var guid = "", name = "", stack: String? = nil
                // read struct fields
                while true {
                    let f = r.readFieldBegin()
                    if f.type == 0 { break }
                    switch f.id {
                    case 1: guid = r.readString() // guid
                    case 2: name = r.readString() // name
                    case 10: stack = r.readString() // stack
                    default: r.skipField(type: f.type)
                    }
                }
                notebooks.append(Notebook(guid: guid, name: name, stack: stack))
            }
        }
        return notebooks
    }

    // MARK: - findNotesMetadata

    func listNotes(notebookGuid: String? = nil, offset: Int = 0, maxNotes: Int = 25) async throws -> (total: Int, notes: [NoteMeta]) {
        let w = ThriftWriter()
        w.writeMessageBegin("findNotesMetadata", type: 1, seqId: nextSeqId())

        // arg 1: token
        w.writeFieldBegin(type: T_STRING, id: 1)
        w.writeString(token)

        // arg 2: filter (NoteFilter struct)
        w.writeFieldBegin(type: T_STRUCT, id: 2)
        if let nbGuid = notebookGuid {
            w.writeFieldBegin(type: T_STRING, id: 2) // notebookGuid
            w.writeString(nbGuid)
        }
        w.writeFieldBegin(type: T_I32, id: 1) // order = UPDATED
        w.writeI32(2)
        w.writeFieldBegin(type: T_BOOL, id: 6) // ascending = false
        w.writeBool(false)
        w.writeFieldStop() // end filter

        // arg 3: offset
        w.writeFieldBegin(type: T_I32, id: 3)
        w.writeI32(Int32(offset))

        // arg 4: maxNotes
        w.writeFieldBegin(type: T_I32, id: 4)
        w.writeI32(Int32(maxNotes))

        // arg 5: resultSpec (NotesMetadataResultSpec struct)
        w.writeFieldBegin(type: T_STRUCT, id: 5)
        w.writeFieldBegin(type: T_BOOL, id: 2); w.writeBool(true)  // includeTitle
        w.writeFieldBegin(type: T_BOOL, id: 5); w.writeBool(true)  // includeCreated
        w.writeFieldBegin(type: T_BOOL, id: 6); w.writeBool(true)  // includeUpdated
        w.writeFieldBegin(type: T_BOOL, id: 10); w.writeBool(true) // includeNotebookGuid
        w.writeFieldStop() // end resultSpec

        w.writeFieldStop() // end args

        let resp = try await call(w.data)
        let r = ThriftReader(resp)
        _ = r.readMessageBegin()

        var totalNotes: Int32 = 0
        var notes: [NoteMeta] = []

        // response is a struct with field 0 = result struct
        let topField = r.readFieldBegin()
        if topField.type == T_STRUCT {
            while true {
                let f = r.readFieldBegin()
                if f.type == 0 { break }
                switch f.id {
                case 1: // startIndex
                    _ = r.readI32()
                case 2: // totalNotes
                    totalNotes = r.readI32()
                case 3: // notes list
                    let _ = r.readByte() // elem type
                    let count = r.readI32()
                    for _ in 0..<count {
                        var guid = "", title = "", nbGuid = ""
                        var created: Int64 = 0, updated: Int64 = 0
                        while true {
                            let nf = r.readFieldBegin()
                            if nf.type == 0 { break }
                            switch nf.id {
                            case 1: guid = r.readString()
                            case 2: title = r.readString()
                            case 5: created = r.readI64()
                            case 6: updated = r.readI64()
                            case 10: nbGuid = r.readString()
                            default: r.skipField(type: nf.type)
                            }
                        }
                        notes.append(NoteMeta(guid: guid, title: title, created: created, updated: updated, notebookGuid: nbGuid))
                    }
                default:
                    r.skipField(type: f.type)
                }
            }
        }
        return (Int(totalNotes), notes)
    }

    // MARK: - getNote

    func getNote(guid: String) async throws -> NoteContent {
        let w = ThriftWriter()
        w.writeMessageBegin("getNote", type: 1, seqId: nextSeqId())

        w.writeFieldBegin(type: T_STRING, id: 1); w.writeString(token) // token
        w.writeFieldBegin(type: T_STRING, id: 2); w.writeString(guid) // guid
        w.writeFieldBegin(type: T_BOOL, id: 3); w.writeBool(true) // withContent
        w.writeFieldBegin(type: T_BOOL, id: 4); w.writeBool(false) // withResourcesData
        w.writeFieldBegin(type: T_BOOL, id: 5); w.writeBool(false) // withResourcesRecognition
        w.writeFieldBegin(type: T_BOOL, id: 6); w.writeBool(false) // withResourcesAlternateData
        w.writeFieldStop()

        let resp = try await call(w.data)
        let r = ThriftReader(resp)
        _ = r.readMessageBegin()

        var noteGuid = "", title = "", content = ""
        var created: Int64 = 0, updated: Int64 = 0

        let topField = r.readFieldBegin()
        if topField.type == T_STRUCT {
            while true {
                let f = r.readFieldBegin()
                if f.type == 0 { break }
                switch f.id {
                case 1: noteGuid = r.readString()
                case 2: title = r.readString()
                case 3: content = r.readString()
                case 5: created = r.readI64()
                case 6: updated = r.readI64()
                default: r.skipField(type: f.type)
                }
            }
        }
        return NoteContent(guid: noteGuid, title: title, content: content, created: created, updated: updated)
    }

    // MARK: - createNote

    func createNote(title: String, body: String, notebookGuid: String? = nil) async throws -> String {
        let enml = """
        <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE en-note SYSTEM "http://xml.evernote.com/pub/enml2.dtd"><en-note>\(body)</en-note>
        """

        let w = ThriftWriter()
        w.writeMessageBegin("createNote", type: 1, seqId: nextSeqId())

        w.writeFieldBegin(type: T_STRING, id: 1); w.writeString(token) // token

        // arg 2: Note struct
        w.writeFieldBegin(type: T_STRUCT, id: 2)
        w.writeFieldBegin(type: T_STRING, id: 2); w.writeString(title) // title
        w.writeFieldBegin(type: T_STRING, id: 3); w.writeString(enml) // content
        if let nbGuid = notebookGuid {
            w.writeFieldBegin(type: T_STRING, id: 10); w.writeString(nbGuid) // notebookGuid
        }
        w.writeFieldStop() // end Note struct

        w.writeFieldStop() // end args

        let resp = try await call(w.data)
        let r = ThriftReader(resp)
        _ = r.readMessageBegin()

        let topField = r.readFieldBegin()
        if topField.type == T_STRUCT {
            while true {
                let f = r.readFieldBegin()
                if f.type == 0 { break }
                if f.id == 1 { return r.readString() } // guid
                r.skipField(type: f.type)
            }
        }
        throw APIError.createFailed
    }

    // MARK: - updateNote

    func updateNote(guid: String, title: String, content: String) async throws -> String {
        let w = ThriftWriter()
        w.writeMessageBegin("updateNote", type: 1, seqId: nextSeqId())

        w.writeFieldBegin(type: T_STRING, id: 1); w.writeString(token)

        // arg 2: Note struct
        w.writeFieldBegin(type: T_STRUCT, id: 2)
        w.writeFieldBegin(type: T_STRING, id: 1); w.writeString(guid) // guid
        w.writeFieldBegin(type: T_STRING, id: 2); w.writeString(title) // title
        w.writeFieldBegin(type: T_STRING, id: 3); w.writeString(content) // content
        w.writeFieldStop() // end Note struct

        w.writeFieldStop() // end args

        let resp = try await call(w.data)
        let r = ThriftReader(resp)
        let msg = r.readMessageBegin()

        // type 3 = EXCEPTION
        if msg.type == 3 {
            // Read the TApplicationException struct for a message
            var errMsg = "Evernote exception"
            while r.remaining > 0 {
                let f = r.readFieldBegin()
                if f.type == 0 { break }
                if f.id == 1 && f.type == T_STRING { errMsg = r.readString() }
                else { r.skipField(type: f.type) }
            }
            throw APIError.serverError(errMsg)
        }

        let topField = r.readFieldBegin()
        // field id 0 = success result, field id 1+ = exception structs
        if topField.id == 0 && topField.type == T_STRUCT {
            while r.remaining > 0 {
                let f = r.readFieldBegin()
                if f.type == 0 { break }
                if f.id == 1 { return r.readString() } // guid
                r.skipField(type: f.type)
            }
        } else if topField.type == T_STRUCT {
            // Exception struct (EDAMUserException, EDAMNotFoundException, etc.)
            var errMsg = "Update rejected (field \(topField.id))"
            while r.remaining > 0 {
                let f = r.readFieldBegin()
                if f.type == 0 { break }
                if f.type == T_STRING { errMsg = r.readString() }
                else { r.skipField(type: f.type) }
            }
            throw APIError.serverError(errMsg)
        }
        return guid
    }

    // MARK: - deleteNote

    func deleteNote(guid: String) async throws {
        let w = ThriftWriter()
        w.writeMessageBegin("deleteNote", type: 1, seqId: nextSeqId())
        w.writeFieldBegin(type: T_STRING, id: 1); w.writeString(token)
        w.writeFieldBegin(type: T_STRING, id: 2); w.writeString(guid)
        w.writeFieldStop()

        _ = try await call(w.data)
    }

    // MARK: - search

    func searchNotes(query: String, maxNotes: Int = 25) async throws -> [NoteMeta] {
        let w = ThriftWriter()
        w.writeMessageBegin("findNotesMetadata", type: 1, seqId: nextSeqId())

        w.writeFieldBegin(type: T_STRING, id: 1); w.writeString(token)

        // filter with words
        w.writeFieldBegin(type: T_STRUCT, id: 2)
        w.writeFieldBegin(type: T_STRING, id: 3) // words
        w.writeString(query)
        w.writeFieldBegin(type: T_I32, id: 1) // order = RELEVANCE
        w.writeI32(1)
        w.writeFieldStop()

        w.writeFieldBegin(type: T_I32, id: 3); w.writeI32(0) // offset
        w.writeFieldBegin(type: T_I32, id: 4); w.writeI32(Int32(maxNotes))

        w.writeFieldBegin(type: T_STRUCT, id: 5)
        w.writeFieldBegin(type: T_BOOL, id: 2); w.writeBool(true)  // includeTitle
        w.writeFieldBegin(type: T_BOOL, id: 5); w.writeBool(true)  // includeCreated
        w.writeFieldBegin(type: T_BOOL, id: 6); w.writeBool(true)  // includeUpdated
        w.writeFieldBegin(type: T_BOOL, id: 10); w.writeBool(true) // includeNotebookGuid
        w.writeFieldStop()

        w.writeFieldStop()

        let resp = try await call(w.data)
        let r = ThriftReader(resp)
        _ = r.readMessageBegin()

        var notes: [NoteMeta] = []
        let topField = r.readFieldBegin()
        if topField.type == T_STRUCT {
            while true {
                let f = r.readFieldBegin()
                if f.type == 0 { break }
                if f.id == 3 { // notes list
                    let _ = r.readByte()
                    let count = r.readI32()
                    for _ in 0..<count {
                        var guid = "", title = "", nbGuid = ""
                        var created: Int64 = 0, updated: Int64 = 0
                        while true {
                            let nf = r.readFieldBegin()
                            if nf.type == 0 { break }
                            switch nf.id {
                            case 1: guid = r.readString()
                            case 2: title = r.readString()
                            case 5: created = r.readI64()
                            case 6: updated = r.readI64()
                            case 10: nbGuid = r.readString()
                            default: r.skipField(type: nf.type)
                            }
                        }
                        notes.append(NoteMeta(guid: guid, title: title, created: created, updated: updated, notebookGuid: nbGuid))
                    }
                } else {
                    r.skipField(type: f.type)
                }
            }
        }
        return notes
    }

    enum APIError: LocalizedError {
        case httpError(Int)
        case createFailed
        case serverError(String)

        var errorDescription: String? {
            switch self {
            case .httpError(let code): return "HTTP error: \(code)"
            case .createFailed: return "Failed to create note"
            case .serverError(let msg): return "Server error: \(msg)"
            }
        }
    }
}
