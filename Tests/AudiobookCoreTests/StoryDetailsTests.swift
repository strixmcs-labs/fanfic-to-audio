import Foundation
import AVFAudio
import Testing
@testable import AudiobookCore

/// The story's category and ratings travel from the downloaded EPUB into the audiobook's tags.
struct StoryDetailsTests {
    @Test func readerUsesTheRecordedCategoryAndRatings() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try epub(root, name: "recorded.epub", metadata: """
            <meta name="fanfictoaudio:category" content="Loving Wives"/>\
            <meta name="fanfictoaudio:average-rating" content="4.52"/>
            """)
        let details = try EPUBReader.read(source).details
        #expect(details == StoryDetails(category: "Loving Wives", averageRating: "4.52"))
        #expect(details.labelled == ["Category: Loving Wives", "Average rating: 4.52"])
    }

    @Test func olderFanFicFareBooksFallBackToTheTitlePage() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let titlePage = "<html><body><h3>Story</h3><b>Category:</b> Harry Potter<br/><b>Rating:</b> Teen And Up<br/><b>Average Rating:</b> 4.1<br/></body></html>"
        let older = try epub(root, name: "older.epub", metadata: "<dc:contributor>FanFicFare [https://github.com/JimmXinu/FanFicFare]</dc:contributor>",
                             titlePage: titlePage)
        #expect(try EPUBReader.read(older).details == StoryDetails(category: "Harry Potter", rating: "Teen And Up", averageRating: "4.1"))
        // Other books' title pages are not mined for labels.
        let other = try epub(root, name: "other.epub", metadata: "", titlePage: titlePage)
        #expect(try EPUBReader.read(other).details.isEmpty)
    }

    @Test func seriesKeepsEachCategoryOnceAndTheFirstRatings() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try epub(root, name: "one.epub", metadata: "<meta name=\"fanfictoaudio:category\" content=\"Loving Wives\"/><meta name=\"fanfictoaudio:average-rating\" content=\"4.52\"/>")
        let second = try epub(root, name: "two.epub", metadata: "<meta name=\"fanfictoaudio:category\" content=\"Loving Wives\"/><meta name=\"fanfictoaudio:average-rating\" content=\"4.80\"/>")
        let third = try epub(root, name: "three.epub", metadata: "<meta name=\"fanfictoaudio:category\" content=\"Romance &amp; Love\"/>")
        let destination = root.appendingPathComponent("series.epub")
        let combined = try EPUBMerger.combine([first, second, third], title: "Series", destination: destination)
        let expected = StoryDetails(category: "Loving Wives, Romance & Love", averageRating: "4.52")
        #expect(combined.details == expected)
        #expect(try EPUBReader.read(destination).details == expected)
    }

    @Test func audioTagsCarryCategoryRatingsAndNarration() {
        let ffmpeg = URL(fileURLWithPath: "/usr/bin/true")
        let book = book(details: StoryDetails(category: "Loving Wives", rating: "Explicit", averageRating: "4.52"))
        let options = ExportOptions(voice: "", wordsPerMinute: 175, bitrate: 128, mode: .single, chapterIDs: ["1"], ffmpeg: ffmpeg,
                                    api: APINarration(provider: .openAI, model: "m", voice: "v", apiKey: "k"))
        #expect(AudiobookExporter.descriptiveMetadata(book, options) == [
            "grouping=Loving Wives",
            "comment=Category: Loving Wives · Rating: Explicit · Average rating: 4.52 · AI-generated narration using \(NarrationProvider.openAI.rawValue)"])
        let plain = ExportOptions(voice: "", wordsPerMinute: 175, bitrate: 128, mode: .single, chapterIDs: ["1"], ffmpeg: ffmpeg)
        #expect(AudiobookExporter.descriptiveMetadata(self.book(details: StoryDetails()), plain).isEmpty)
    }

    @Test(arguments: [ExportMode.single, .chapters, .m4b]) func exportedAudioIsTagged(mode: ExportMode) async throws {
        let ffmpeg = try #require(SpeechTools.findFFmpeg())
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let data = try audioFixture(root)
        let client = APISpeechClient(transport: { request in (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) })
        let destination = root.appendingPathComponent(mode == .m4b ? "book.m4b" : mode == .chapters ? "chapters" : "book.mp3")
        let options = ExportOptions(voice: "", wordsPerMinute: 175, bitrate: 128, mode: mode, chapterIDs: ["1"], ffmpeg: ffmpeg,
                                    api: APINarration(provider: .openAI, model: "m", voice: "v", apiKey: "k"))
        let book = book(details: StoryDetails(category: "Loving Wives", averageRating: "4.52"))
        _ = try await AudiobookExporter.export(book: book, options: options, destination: destination, apiClient: client)
        let file = mode == .chapters
            ? destination.appendingPathComponent(try #require(FileManager.default.contentsOfDirectory(atPath: destination.path).first { $0.hasSuffix(".mp3") }))
            : destination
        if mode == .m4b {
            let tags = try await formatTags(file, ffmpeg: ffmpeg)
            #expect(tags["grouping"] == "Loving Wives")
            #expect(tags["comment"]?.hasPrefix("Category: Loving Wives · Average rating: 4.52") == true)
        } else {
            // Standard frames that Finder, Music, and other players show, not FFmpeg's TXXX stand-ins.
            let frames = try ID3Tag.frames(in: file)
            let comment = "Category: Loving Wives · Average rating: 4.52 · AI-generated narration using \(NarrationProvider.openAI.rawValue)"
            #expect(frames.first { $0.id == "COMM" }?.text == comment)
            #expect(frames.first { $0.id == "TIT1" }?.text == "Loving Wives")
            #expect(frames.first { $0.id == "GRP1" }?.text == "Loving Wives")
            #expect(frames.first { $0.id == "TXXX" && $0.label == "Category" }?.text == "Loving Wives")
            #expect(frames.first { $0.id == "TXXX" && $0.label == "Average Rating" }?.text == "4.52")
            #expect(!frames.contains { $0.id == "TXXX" && ["comment", "grouping"].contains($0.label) })
            #expect(frames.first { $0.id == "TIT2" }?.text == (mode == .single ? "Tagged" : "One"))
            // The audio is untouched: FFprobe still reads the same stream and its standard tags.
            let tags = try await formatTags(file, ffmpeg: ffmpeg)
            #expect(tags["comment"] == comment)
            #expect(tags["artist"] == "Test")
        }
    }

    @Test func id3FramesKeepUnicodeAndReplaceEarlierValues() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("tagged.mp3")
        let audio = Data([0xFF, 0xFB, 0x90, 0x64] + Array(repeating: 0x55, count: 4096))
        try (Data("ID3".utf8) + Data([3, 0, 0, 0, 0, 0, 0]) + audio).write(to: file)
        try ID3Tag.write(ID3Tag.storyFrames(StoryDetails(category: "Puella Magi/魔法少女", rating: "Explicit"), comment: "First"), to: file)
        try ID3Tag.write(ID3Tag.storyFrames(StoryDetails(category: "Loving Wives", averageRating: "4.43"), comment: "Second"), to: file)
        let frames = try ID3Tag.frames(in: file)
        #expect(frames.filter { $0.id == "COMM" }.map(\.text) == ["Second"])
        #expect(frames.filter { $0.id == "TIT1" }.map(\.text) == ["Loving Wives"])
        #expect(frames.first { $0.label == "Rating" }?.text == "Explicit") // Not replaced: the second book had no rating.
        try ID3Tag.write([ID3Tag.text("TIT2", "魔法少女まどか★マギカ")], to: file)
        #expect(try ID3Tag.frames(in: file).first { $0.id == "TIT2" }?.text == "魔法少女まどか★マギカ")
        #expect(try Data(contentsOf: file).suffix(audio.count) == audio)
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("story-details-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false); return url
    }
    private func epub(_ root: URL, name: String, metadata: String, titlePage: String? = nil) throws -> URL {
        let url = root.appendingPathComponent(name)
        let titleItem = titlePage == nil ? "" : "<item id=\"title_page\" href=\"title_page.xhtml\" media-type=\"application/xhtml+xml\"/>"
        let titleRef = titlePage == nil ? "" : "<itemref idref=\"title_page\"/>"
        var resources: [(String, Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data("<container><rootfiles><rootfile full-path=\"content.opf\"/></rootfiles></container>".utf8)),
            ("content.opf", Data("<package xmlns=\"http://www.idpf.org/2007/opf\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:title>\(name)</dc:title>\(metadata)</metadata><manifest>\(titleItem)<item id=\"text\" href=\"chapter.xhtml\" media-type=\"application/xhtml+xml\"/></manifest><spine>\(titleRef)<itemref idref=\"text\"/></spine></package>".utf8)),
            ("chapter.xhtml", Data("<html><body><p>Story text.</p></body></html>".utf8))]
        if let titlePage { resources.append(("title_page.xhtml", Data(titlePage.utf8))) }
        try EPUBZIPWriter.encode(resources).write(to: url)
        return url
    }
    private func book(details: StoryDetails) -> EPUBBook {
        EPUBBook(title: "Tagged", author: "Test", language: "en", chapters: [BookChapter(id: "1", title: "One", text: "First passage.")],
                 source: URL(fileURLWithPath: "/tmp/tagged.epub"), details: details)
    }
    private func audioFixture(_ root: URL) throws -> Data {
        let url = root.appendingPathComponent("fixture.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2400)!
        buffer.frameLength = 2400
        for index in 0..<2400 { buffer.floatChannelData![0][index] = sin(Float(index) * 0.12) * 0.3 }
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        return try Data(contentsOf: url)
    }
    private func formatTags(_ url: URL, ffmpeg: URL) async throws -> [String: String] {
        let ffprobe = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
        let result = try await ProcessRunner().run(ffprobe, arguments: ["-v", "error", "-show_format", "-of", "json", url.path])
        let info = try #require(JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8)) as? [String: Any])
        let tags = (info["format"] as? [String: Any])?["tags"] as? [String: String] ?? [:]
        return Dictionary(tags.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
    }
}
