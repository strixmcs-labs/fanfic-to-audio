import Foundation

/// Writes the standard ID3v2 frames FFmpeg's MP3 muxer cannot: it stores "comment" and
/// "grouping" as user-defined TXXX frames, which Finder, Music, and most players never show.
/// Frames are added to the tag FFmpeg wrote; the audio after the tag is copied unchanged.
public enum ID3Tag {
    public struct Frame: Equatable, Sendable {
        public let id: String
        public let body: Data
        var flags = Data([0, 0])

        /// The text of a text, comment, or user-defined frame; for TXXX and COMM, the value after the description.
        public var text: String {
            guard let encoding = body.first else { return "" }
            var rest = body.dropFirst()
            if id == "COMM" { rest = rest.dropFirst(3) }
            let parts = ID3Tag.strings(rest, encoding: encoding)
            return (id == "TXXX" || id == "COMM" ? parts.dropFirst().first : parts.first) ?? ""
        }
        /// The description of a TXXX or COMM frame.
        public var label: String {
            guard id == "TXXX" || id == "COMM", let encoding = body.first else { return "" }
            return ID3Tag.strings(body.dropFirst(id == "COMM" ? 4 : 1), encoding: encoding).first ?? ""
        }
    }

    public static func text(_ id: String, _ value: String) -> Frame { Frame(id: id, body: Data([1]) + utf16(value)) }
    public static func comment(_ value: String) -> Frame { Frame(id: "COMM", body: Data([1]) + Data("eng".utf8) + utf16("") + Data([0, 0]) + utf16(value)) }
    public static func userText(_ label: String, _ value: String) -> Frame { Frame(id: "TXXX", body: Data([1]) + utf16(label) + Data([0, 0]) + utf16(value)) }

    /// The story's category as grouping (TIT1 for older players, GRP1 for Music), labelled
    /// Category, Rating, and Average Rating fields, and one comment for players that show only comments.
    public static func storyFrames(_ details: StoryDetails, comment: String) -> [Frame] {
        var frames: [Frame] = []
        if !details.category.isEmpty {
            frames += [text("TIT1", details.category), text("GRP1", details.category), userText("Category", details.category)]
        }
        if !details.rating.isEmpty { frames.append(userText("Rating", details.rating)) }
        if !details.averageRating.isEmpty { frames.append(userText("Average Rating", details.averageRating)) }
        if !comment.isEmpty { frames.append(self.comment(comment)) }
        return frames
    }

    /// The frames in a file's ID3v2.3 or 2.4 tag, or none when it has no tag.
    public static func frames(in url: URL) throws -> [Frame] { try read(url).frames }

    /// Adds frames to the file's tag, replacing frames with the same ID (TXXX by label) and
    /// FFmpeg's unreadable "comment" and "grouping" TXXX frames.
    public static func write(_ frames: [Frame], to url: URL) throws {
        guard !frames.isEmpty else { return }
        let existing = try read(url)
        let replacedIDs = Set(frames.map(\.id).filter { $0 != "TXXX" })
        let replacedLabels = Set(frames.filter { $0.id == "TXXX" }.map { $0.label.lowercased() } + ["comment", "grouping"])
        let kept = existing.frames.filter { frame in
            frame.id == "TXXX" ? !replacedLabels.contains(frame.label.lowercased()) : !replacedIDs.contains(frame.id)
        }
        var tag = Data()
        for frame in kept + frames {
            tag += Data(frame.id.utf8.prefix(4))
            tag += existing.version == 4 ? synchsafe(frame.body.count) : bigEndian(frame.body.count)
            tag += frame.flags + frame.body
        }
        guard tag.count < 1 << 28 else { throw AudiobookError.conversion("The MP3 tags are too large.") }
        let temp = url.deletingLastPathComponent().appendingPathComponent(".id3-\(UUID().uuidString).mp3")
        guard FileManager.default.createFile(atPath: temp.path, contents: Data("ID3".utf8) + Data([existing.version, 0, 0]) + synchsafe(tag.count) + tag) else {
            throw AudiobookError.conversion("The MP3 tags could not be written.")
        }
        do {
            let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
            let output = try FileHandle(forWritingTo: temp); defer { try? output.close() }
            try output.seekToEnd()
            try input.seek(toOffset: existing.audioStart)
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty { try output.write(contentsOf: chunk) }
            try output.synchronize()
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    private static func read(_ url: URL) throws -> (version: UInt8, frames: [Frame], audioStart: UInt64) {
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        let header = try input.read(upToCount: 10) ?? Data()
        guard header.count == 10, header.starts(with: Data("ID3".utf8)) else { return (3, [], 0) }
        let version = header[3], flags = header[5], size = unsynchsafe(header, at: 6)
        // FFmpeg writes plain 2.3 tags; anything unsynchronised or with an extended header is left alone.
        guard version == 3 || version == 4, flags & 0xC0 == 0 else { throw AudiobookError.conversion("The MP3 tag format is not supported.") }
        let body = try input.read(upToCount: size) ?? Data()
        var frames: [Frame] = []
        var position = 0
        while position + 10 <= body.count, body[position] != 0 {
            let id = String(decoding: body[position..<position + 4], as: UTF8.self)
            let length = version == 4 ? unsynchsafe(body, at: position + 4)
                : body[position + 4..<position + 8].reduce(0) { $0 << 8 | Int($1) }
            guard position + 10 + length <= body.count else { break }
            frames.append(Frame(id: id, body: body.subdata(in: position + 10..<position + 10 + length),
                                flags: body.subdata(in: position + 8..<position + 10)))
            position += 10 + length
        }
        return (version, frames, 10 + UInt64(size) + (flags & 0x10 != 0 ? 10 : 0))
    }

    private static func utf16(_ value: String) -> Data { Data([0xFF, 0xFE]) + (value.data(using: .utf16LittleEndian) ?? Data()) }
    private static func bigEndian(_ value: Int) -> Data { Data([24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }) }
    private static func synchsafe(_ value: Int) -> Data { Data([21, 14, 7, 0].map { UInt8((value >> $0) & 0x7F) }) }
    private static func unsynchsafe(_ data: Data, at offset: Int) -> Int {
        (0..<4).reduce(0) { $0 << 7 | Int(data[data.startIndex + offset + $1] & 0x7F) }
    }

    /// Splits terminated strings in an ID3 text encoding (0 Latin-1, 1 UTF-16 with BOM, 2 UTF-16BE, 3 UTF-8).
    fileprivate static func strings(_ data: Data.SubSequence, encoding: UInt8) -> [String] {
        let bytes = Array(data)
        let wide = encoding == 1 || encoding == 2
        var parts: [[UInt8]] = [], current: [UInt8] = [], index = 0
        while index < bytes.count {
            if wide, index + 1 < bytes.count {
                if bytes[index] == 0 && bytes[index + 1] == 0 { parts.append(current); current = [] } else { current += bytes[index...index + 1] }
                index += 2
            } else {
                if bytes[index] == 0 { parts.append(current); current = [] } else { current.append(bytes[index]) }
                index += 1
            }
        }
        parts.append(current)
        return parts.map { part in
            switch encoding {
            case 0: return String(decoding: part.map { UInt16($0) }, as: UTF16.self)
            case 1: return String(data: Data(part), encoding: .utf16) ?? ""
            case 2: return String(data: Data(part), encoding: .utf16BigEndian) ?? ""
            default: return String(decoding: part, as: UTF8.self)
            }
        }
    }
}
