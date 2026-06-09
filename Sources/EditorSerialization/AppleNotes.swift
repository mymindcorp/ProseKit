import Foundation

// Apple Notes puts a private `com.apple.notes.richtext` flavor on the pasteboard:
// an NSKeyedArchiver bplist wrapping a raw protobuf ("Note") whose attribute runs
// carry per-paragraph checklist state — the one place the checked/unchecked status
// survives (RTF flattens it). We read just enough of that proto to recover which
// lines are checklist items and which are checked.
//
// This is a PRIVATE, undocumented format. Everything here is defensive: any
// structural surprise (renumbered fields, changed style code, truncation) makes a
// parse step return nil, and the caller falls back to RTF-only behavior. It never
// throws or traps.

public enum AppleNotesPasteboard {
    /// Recover checklist info from the `com.apple.notes.richtext` archive: every
    /// checklist line in note order with its checked state. Returns nil if the
    /// archive can't be parsed or contains no checklist (→ caller falls back).
    public static func checklist(fromArchive data: Data) -> [(text: String, checked: Bool)]? {
        for blob in noteBlobs(fromArchive: data) {
            if let result = parseNoteProto(blob) { return result }
        }
        return nil
    }

    /// The candidate Note-proto payloads inside the keyed archive. The proto
    /// lives in one of the archive's NSData blobs; hunt for it rather than
    /// resolving keyed-archive references (more robust to layout).
    static func noteBlobs(fromArchive data: Data) -> [Data] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any],
              let objects = dict["$objects"] as? [Any] else { return [] }
        var blobs: [Data] = []
        for o in objects {
            if let d = o as? Data { blobs.append(d) }
            else if let inner = o as? [String: Any], let d = inner["NS.data"] as? Data { blobs.append(d) }
        }
        return blobs
    }

    /// Parse the Note protobuf. Returns every checklist line in note order with
    /// its checked state, or nil if the bytes aren't this proto or hold no
    /// checklist paragraph.
    public static func parseNoteProto(_ data: Data) -> [(text: String, checked: Bool)]? {
        let b = [UInt8](data)
        guard let (text, runs) = parseNote(b), !runs.isEmpty else { return nil }
        let units = Array(text.utf16)
        guard !units.isEmpty else { return nil }
        var checkFlag = [Bool](repeating: false, count: units.count)
        var doneFlag = [Bool](repeating: false, count: units.count)
        var pos = 0
        var sawChecklist = false
        for run in runs {
            // Clamp to the remaining units before adding — run.length comes from
            // an untrusted varint and pos + length could overflow.
            let end = pos + min(max(0, run.length), units.count - pos)
            if run.styleType == 103, pos < end {
                sawChecklist = true
                for k in pos..<end { checkFlag[k] = true; doneFlag[k] = run.done }
            }
            pos = end
            if pos >= units.count { break }
        }
        guard sawChecklist else { return nil }
        // Split note_text into lines; a line is a checklist item if any of its units
        // are flagged, checked if any are done.
        var lines: [(text: String, checked: Bool)] = []
        var start = 0
        for k in 0...units.count {
            if k == units.count || units[k] == 0x0A {
                if k > start, (start..<k).contains(where: { checkFlag[$0] }) {
                    let line = String(decoding: Array(units[start..<k]), as: UTF16.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !line.isEmpty {
                        lines.append((line, (start..<k).contains(where: { doneFlag[$0] })))
                    }
                }
                start = k + 1
            }
        }
        return lines.isEmpty ? nil : lines
    }

    // MARK: - Minimal, bounds-checked protobuf reader (wire types varint + length).

    private static func readVarint(_ b: [UInt8], _ i: inout Int) -> UInt64? {
        var shift: UInt64 = 0, result: UInt64 = 0, n = 0
        while i < b.count {
            let byte = b[i]; i += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7; n += 1
            if n > 9 { return nil }
        }
        return nil
    }

    private static func readTag(_ b: [UInt8], _ i: inout Int) -> (field: Int, wire: Int)? {
        guard let t = readVarint(b, &i) else { return nil }
        return (Int(t >> 3), Int(t & 7))
    }

    /// Read a length-delimited chunk (wire type 2). The length varint is
    /// untrusted: convert and bound it without trapping (`Int(l)` and `i + len`
    /// would crash on crafted input).
    private static func readChunk(_ b: [UInt8], _ i: inout Int) -> [UInt8]? {
        guard let l = readVarint(b, &i), let len = Int(exactly: l), len <= b.count - i else { return nil }
        defer { i += len }
        return Array(b[i..<i + len])
    }

    /// Skip a field of the given wire type. Returns false on malformed input.
    private static func skip(_ b: [UInt8], _ i: inout Int, _ wire: Int) -> Bool {
        switch wire {
        case 0: return readVarint(b, &i) != nil
        case 2: return readChunk(b, &i) != nil
        case 5: i += 4; return i <= b.count
        case 1: i += 8; return i <= b.count
        default: return false
        }
    }

    /// One AttributeRun: a span of note_text (in UTF-16 units) plus the block
    /// style and inline formatting that apply to it. Style types observed in the
    /// wild: 0 title, 1 heading, 2 subheading, 4 monospaced, 100 dotted list,
    /// 101 dashed list, 102 numbered list, 103 checklist; -1/absent = body.
    struct NoteRun {
        var length = 0
        var styleType = -1
        var indent = 0
        var done = false
        var bold = false
        var italic = false
        var underline = false
        var strike = false
        var link: String?
    }

    // Note { string note_text = 2; repeated AttributeRun attribute_run = 5 }
    static func parseNote(_ b: [UInt8]) -> (text: String, runs: [NoteRun])? {
        var i = 0, text: String?
        var runs: [NoteRun] = []
        while i < b.count {
            guard let (field, wire) = readTag(b, &i) else { return nil }
            if field == 2, wire == 2 {
                guard let c = readChunk(b, &i) else { return nil }
                text = String(decoding: c, as: UTF8.self)
            } else if field == 5, wire == 2 {
                guard let c = readChunk(b, &i) else { return nil }
                if let r = parseRun(c) { runs.append(r) }
            } else if !skip(b, &i, wire) { return nil }
        }
        guard let t = text else { return nil }
        return (t, runs)
    }

    // AttributeRun { int32 length = 1; ParagraphStyle paragraph_style = 2;
    //                int32 font_weight = 5 (1 bold, 2 italic, 3 both);
    //                int32 underlined = 6; int32 strikethrough = 7;
    //                string link = 9 }
    private static func parseRun(_ b: [UInt8]) -> NoteRun? {
        var i = 0
        var run = NoteRun()
        while i < b.count {
            guard let (field, wire) = readTag(b, &i) else { return nil }
            switch (field, wire) {
            case (1, 0):
                guard let v = readVarint(b, &i), let l = Int(exactly: v) else { return nil }
                run.length = l
            case (2, 2):
                guard let c = readChunk(b, &i) else { return nil }
                if let ps = parseParagraphStyle(c) {
                    run.styleType = ps.styleType
                    run.indent = ps.indent
                    if ps.styleType == 103 { run.done = ps.done }
                }
            case (5, 0):
                guard let v = readVarint(b, &i) else { return nil }
                run.bold = v == 1 || v == 3
                run.italic = v == 2 || v == 3
            case (6, 0):
                guard let v = readVarint(b, &i) else { return nil }
                run.underline = v != 0
            case (7, 0):
                guard let v = readVarint(b, &i) else { return nil }
                run.strike = v != 0
            case (9, 2):
                guard let c = readChunk(b, &i) else { return nil }
                run.link = String(decoding: c, as: UTF8.self)
            default:
                if !skip(b, &i, wire) { return nil }
            }
        }
        return run
    }

    // ParagraphStyle { int32 style_type = 1; int32 indent_amount = 4;
    //                  Checklist checklist = 5 }; 103 = checklist.
    private static func parseParagraphStyle(_ b: [UInt8]) -> (styleType: Int, indent: Int, done: Bool)? {
        var i = 0, styleType = -1, indent = 0, done = false
        while i < b.count {
            guard let (field, wire) = readTag(b, &i) else { return nil }
            if field == 1, wire == 0 {
                guard let v = readVarint(b, &i), let s = Int(exactly: v) else { return nil }; styleType = s
            } else if field == 4, wire == 0 {
                guard let v = readVarint(b, &i), let d = Int(exactly: v) else { return nil }; indent = d
            } else if field == 5, wire == 2 {
                guard let c = readChunk(b, &i) else { return nil }; done = parseChecklistDone(c)
            } else if !skip(b, &i, wire) { return nil }
        }
        return (styleType, indent, done)
    }

    // Checklist { bytes uuid = 1; int32 done = 2 }
    private static func parseChecklistDone(_ b: [UInt8]) -> Bool {
        var i = 0
        while i < b.count {
            guard let (field, wire) = readTag(b, &i) else { return false }
            if field == 2, wire == 0 { return (readVarint(b, &i) ?? 0) != 0 }
            if !skip(b, &i, wire) { return false }
        }
        return false
    }
}
