import Foundation
import Combine

public enum AudiobookJobState: String, Sendable, Codable {
    case queued = "Queued", running = "Converting", done = "Done", failed = "Failed", cancelled = "Cancelled"
}

public struct AudiobookJob: Identifiable, Sendable, Codable {
    public var id = UUID()
    public let source: URL
    public var title: String
    public var author = ""
    public var state: AudiobookJobState = .queued
    public var progress = 0.0
    public var message = "Waiting to convert"
    public var output: URL?
    public var chapterIDs: Set<String>?
    /// Section IDs in a custom reading order; nil follows the EPUB spine.
    public var chapterOrder: [String]?
    /// Custom section titles by section ID.
    public var chapterTitles: [String: String]?
    public var narration: NarrationPreset?

    public init(source: URL, chapterIDs: Set<String>? = nil, chapterOrder: [String]? = nil, chapterTitles: [String: String]? = nil) {
        self.source = source
        self.title = source.deletingPathExtension().lastPathComponent
        self.chapterIDs = chapterIDs
        self.chapterOrder = chapterOrder
        self.chapterTitles = chapterTitles
    }
}

public struct BatchNarrationSettings: Sendable {
    public let voice: String
    public let wordsPerMinute: Int
    public let bitrate: Int
    public let mode: ExportMode
    public let ffmpeg: URL
    public let api: APINarration?
    public let usage: APIUsageLedger?
    public let budget: APIBudget?
    public let budgets: [String: APIBudget]
    public let text: NarrationTextOptions
    public init(voice: String, wordsPerMinute: Int, bitrate: Int, mode: ExportMode, ffmpeg: URL, api: APINarration? = nil, usage: APIUsageLedger? = nil, budget: APIBudget? = nil, budgets: [String: APIBudget] = [:],
                text: NarrationTextOptions = .unchanged) {
        self.voice = voice; self.wordsPerMinute = wordsPerMinute; self.bitrate = bitrate
        self.mode = mode; self.ffmpeg = ffmpeg; self.api = api
        self.usage = usage; self.budget = budget
        self.budgets = budgets; self.text = text
    }
}

/// Reads one EPUB at a time and reuses the transactional audiobook exporter.
@MainActor
public final class AudiobookQueue: ObservableObject {
    public typealias Reader = @Sendable (URL) async throws -> EPUBBook
    public typealias Exporter = @Sendable (EPUBBook, ExportOptions, URL, ProcessRunner, @escaping @Sendable (ExportProgress) -> Void) async throws -> URL

    @Published public private(set) var jobs: [AudiobookJob] = [] { didSet { persist() } }
    @Published public private(set) var persistenceError: String?
    public var onCompletion: ((String) -> Void)?
    private let storage: URL?
    private let checkpointRoot: URL?
    private var persistenceBlocked = false
    public private(set) var selectedID: UUID?
    private struct Snapshot: Codable { let version: Int; let jobs: [AudiobookJob]; let selectedID: UUID? }
    @Published public private(set) var activeBook: (id: UUID, book: EPUBBook)?
    @Published public private(set) var isRunning = false
    @Published public private(set) var summary = "Add EPUBs to create several audiobooks"
    @Published public private(set) var batchProgress = 0.0
    /// The converting book's latest progress, including its section and passage; nil between books.
    @Published public private(set) var activeProgress: ExportProgress?
    private let reader: Reader
    private let exporter: Exporter
    private var task: Task<Void, Never>?
    private var runner: ProcessRunner?
    private var pauseRequested = false
    /// Jobs taken up by the current run, in the order they started.
    private var batchIDs: [UUID] = []
    private var batchFinished = 0
    // Provider keys for the current run, held in memory only and cleared when it ends.
    private var runKeys: [NarrationProvider: String] = [:]

    public init(storage: URL? = nil, checkpointRoot: URL? = nil, reader: @escaping Reader = { url in
        try await EPUBLibrary.shared.read(url)
    }, exporter: @escaping Exporter = { book, options, destination, runner, progress in
        try await AudiobookExporter.export(book: book, options: options, destination: destination,
            runner: runner, progress: progress)
    }) {
        self.reader = reader; self.exporter = exporter
        self.storage = storage; self.checkpointRoot = checkpointRoot
        if let storage, FileManager.default.fileExists(atPath: storage.path) {
            do {
                let saved = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: storage))
                guard saved.version == 1, Set(saved.jobs.map(\.id)).count == saved.jobs.count else {
                    throw AudiobookError.conversion("Unsupported saved queue format.")
                }
                jobs = saved.jobs.map { job in
                    var recovered = job
                    if recovered.state == .running {
                        if let output = recovered.output, FileManager.default.fileExists(atPath: output.path) {
                            recovered.state = .done; recovered.progress = 1; recovered.message = "Recovered completed audiobook"
                        } else {
                            recovered.state = .queued; recovered.message = "Interrupted. Start the queue to resume completed passages."
                        }
                    }
                    return recovered
                }
                selectedID = saved.selectedID
                summary = jobs.count == 1 ? "Restored 1 queue entry" : "Restored \(jobs.count) queue entries"
            } catch {
                persistenceBlocked = true
                persistenceError = "Saved queue could not be read; the original file has been preserved. \(error.localizedDescription)"
            }
        }
    }

    public var queuedCount: Int { jobs.filter { $0.state == .queued }.count }
    /// While the queue runs, every job except the one converting can still be edited.
    public func isLocked(_ id: UUID) -> Bool { jobs.first(where: { $0.id == id })?.state == .running }
    public func rememberSelection(_ id: UUID?) { selectedID = id; persist() }

    /// Adds EPUBs, including while the queue runs; a running queue converts them before it stops.
    @discardableResult public func add(_ urls: [URL], chapterIDs: Set<String>? = nil, chapterOrder: [String]? = nil, chapterTitles: [String: String]? = nil) -> Int {
        var pending = Set(jobs.filter { [.queued, .running].contains($0.state) }.map { $0.source.resolvingSymlinksInPath().standardizedFileURL })
        var added = 0
        for url in urls where url.isFileURL && url.pathExtension.lowercased() == "epub" {
            let canonical = url.resolvingSymlinksInPath().standardizedFileURL
            if pending.insert(canonical).inserted {
                jobs.append(AudiobookJob(source: url, chapterIDs: chapterIDs, chapterOrder: chapterOrder, chapterTitles: chapterTitles)); added += 1
            }
        }
        if added > 0 && !isRunning { summary = "\(queuedCount) " + (queuedCount == 1 ? "EPUB ready to convert" : "EPUBs ready to convert") }
        return added
    }

    public func remove(_ id: UUID) {
        guard !isLocked(id) else { return }
        jobs.removeAll { $0.id == id }
        discardCheckpoint(id)
    }

    public func canMove(_ id: UUID, by offset: Int) -> Bool {
        guard !isLocked(id), abs(offset) == 1, let index = jobs.firstIndex(where: { $0.id == id }) else { return false }
        return jobs.indices.contains(index + offset)
    }

    public func move(_ id: UUID, by offset: Int) {
        guard canMove(id, by: offset), let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs.swapAt(index, index + offset)
    }

    public func replaceWithCombined(_ ids: Set<UUID>, source: URL) {
        guard !isRunning, ids.count >= 2,
              jobs.filter({ ids.contains($0.id) && $0.state == .queued }).count == ids.count,
              let first = jobs.firstIndex(where: { ids.contains($0.id) }) else { return }
        for id in ids { discardCheckpoint(id) }
        jobs.removeAll { ids.contains($0.id) }
        jobs.insert(AudiobookJob(source: source), at: first)
        summary = "Combined EPUB added to the queue"
    }

    public func updateMetadata(_ id: UUID, book: EPUBBook) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].title = book.title; jobs[index].author = book.author
    }

    public func clearFinished() {
        for job in jobs where job.state == .done { discardCheckpoint(job.id) }
        jobs.removeAll { $0.state == .done }
    }

    public func retry(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), [.failed, .cancelled].contains(jobs[index].state) else { return }
        jobs[index].state = .queued; jobs[index].progress = 0
        jobs[index].message = "Waiting to retry"; jobs[index].output = nil
    }

    public func updateSettings(_ id: UUID, chapterIDs: Set<String>, chapterOrder: [String]? = nil, chapterTitles: [String: String]? = nil,
                               narration: NarrationPreset?) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), ![.done, .running].contains(jobs[index].state) else { return }
        jobs[index].chapterIDs = chapterIDs; jobs[index].chapterOrder = chapterOrder
        jobs[index].chapterTitles = chapterTitles; jobs[index].narration = narration
    }

    /// Returns a waiting job to the settings in effect when the queue starts; sections are kept.
    public func clearNarration(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), ![.done, .running].contains(jobs[index].state) else { return }
        jobs[index].narration = nil
    }

    public func move(_ id: UUID, before target: UUID) {
        guard !isLocked(id), id != target, let from = jobs.firstIndex(where: { $0.id == id }) else { return }
        let job = jobs.remove(at: from)
        if let to = jobs.firstIndex(where: { $0.id == target }) { jobs.insert(job, at: to) }
        else { jobs.insert(job, at: min(from, jobs.count)) }
    }

    public func discardCheckpoint(_ id: UUID) {
        guard !isLocked(id) else { return }
        if let root = checkpointRoot { try? FileManager.default.removeItem(at: root.appendingPathComponent(id.uuidString)) }
    }

    private func persist() {
        guard !persistenceBlocked, let storage else { return }
        do {
            try FileManager.default.createDirectory(at: storage.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Snapshot(version: 1, jobs: jobs, selectedID: selectedID)).write(to: storage, options: .atomic)
            if persistenceError != nil { persistenceError = nil }
        } catch { persistenceError = "Could not save the queue: \(error.localizedDescription)" }
    }

    public func start(settings: BatchNarrationSettings, folder: URL,
                      keyResolver: @escaping @Sendable (NarrationProvider) throws -> String = { _ in "" }) throws {
        guard !isRunning, queuedCount > 0 else { return }
        guard !persistenceBlocked else { throw AudiobookError.conversion(persistenceError ?? "The saved queue needs recovery.") }
        try settings.api?.validate()
        guard (settings.api != nil || !settings.voice.isEmpty), SpeechRate.allowedRange.contains(settings.wordsPerMinute), [64, 96, 128, 192].contains(settings.bitrate) else {
            throw AudiobookError.conversion("Choose a voice, valid speaking speed, and MP3 quality before starting the queue.")
        }
        guard folder.isFileURL else { throw AudiobookError.conversion("Choose a local output folder.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let preset = NarrationPreset(voice: settings.voice, wordsPerMinute: settings.wordsPerMinute,
            bitrate: settings.bitrate, mode: settings.mode, api: settings.api, text: settings.text)
        var keys: [NarrationProvider: String] = [:]
        // Resolve credentials before starting the batch, without writing them to disk.
        for job in jobs where job.state == .queued {
            let provider = (job.narration ?? preset).provider
            if provider != .system, keys[provider] == nil {
                keys[provider] = provider == settings.api?.provider ? settings.api?.apiKey : try keyResolver(provider)
                try (job.narration ?? preset).api(key: keys[provider] ?? "")?.validate()
            }
        }
        for index in jobs.indices where jobs[index].state == .queued && jobs[index].narration == nil { jobs[index].narration = preset }
        runKeys = keys
        batchIDs = []
        batchFinished = 0; batchProgress = 0; pauseRequested = false; isRunning = true
        summary = "Starting \(queuedCount) " + (queuedCount == 1 ? "audiobook…" : "audiobooks…")
        task = Task { [self] in
            // Retain the activity between books, not just during individual exports.
            let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Creating queued audiobooks")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            // Take the next waiting job in the current order each time, so books added, moved, or
            // retried during the run are included. Jobs are found by ID after every await, because
            // the list can change while a book converts.
            while !pauseRequested, let id = jobs.first(where: { $0.state == .queued })?.id {
                batchIDs.append(id)
                updateJob(id) { job in
                    job.state = .running; job.message = "Reading EPUB…"
                    if job.narration == nil { job.narration = preset }
                }
                guard let job = jobs.first(where: { $0.id == id }) else { continue }
                summary = progressSummary(job.title)
                batchProgress = Double(batchFinished) / Double(max(1, batchFinished + queuedCount + 1))
                let processRunner = ProcessRunner()
                runner = processRunner
                do {
                    let book = try await reader(job.source)
                    try Task.checkCancellation()
                    updateJob(id) { $0.title = book.title; $0.author = book.author }
                    activeBook = (id, book)
                    let chapterIDs = job.chapterIDs ?? Set(book.chapters.filter(\.includedByDefault).map(\.id))
                    let narration = job.narration ?? preset
                    if narration.provider != .system, runKeys[narration.provider] == nil {
                        // A book added during the run may use a provider not resolved at the start.
                        runKeys[narration.provider] = try keyResolver(narration.provider)
                    }
                    let budget = settings.budgets[narration.pricingID] ?? (narration.provider == settings.api?.provider && narration.model == settings.api?.model
                        ? settings.budget : APIBudget(characterLimit: settings.budget?.characterLimit, costLimit: settings.budget?.costLimit))
                    let options = ExportOptions(voice: narration.voice, wordsPerMinute: narration.wordsPerMinute,
                        bitrate: narration.bitrate, mode: narration.mode, chapterIDs: chapterIDs, ffmpeg: settings.ffmpeg,
                        api: narration.api(key: runKeys[narration.provider] ?? ""),
                        checkpoint: checkpointRoot?.appendingPathComponent(id.uuidString), usage: settings.usage, budget: budget,
                        text: narration.textOptions)
                    let destination = Self.uniqueDestination(title: book.title, folder: folder, mode: narration.mode)
                    updateJob(id) { $0.output = destination }
                    // The open-book view applies the order itself; only the export is rearranged.
                    let result = try await exporter(book.reordered(job.chapterOrder).retitled(job.chapterTitles), options, destination, processRunner) { [weak self] update in
                        Task { @MainActor [weak self] in self?.receive(update, id: id) }
                    }
                    updateJob(id) { $0.output = result; $0.state = .done; $0.progress = 1; $0.message = "Audiobook ready" }
                } catch is CancellationError {
                    updateJob(id) { $0.output = nil; $0.state = .cancelled; $0.progress = 0; $0.message = "Paused. Retry to resume completed passages." }
                } catch let error as APIUsageError {
                    updateJob(id) { $0.output = nil; $0.state = .failed; $0.message = error.localizedDescription }
                    pauseRequested = true
                } catch {
                    updateJob(id) { $0.output = nil; $0.state = .failed; $0.progress = 0; $0.message = error.localizedDescription }
                }
                runner = nil; activeProgress = nil
                batchFinished += 1
                batchProgress = Double(batchFinished) / Double(max(1, batchFinished + queuedCount))
            }
            runKeys = [:]
            let completed = jobs.filter { batchIDs.contains($0.id) && $0.state == .done }.count
            let failed = jobs.filter { batchIDs.contains($0.id) && $0.state == .failed }.count
            if pauseRequested {
                summary = "Queue paused. \(completed) ready; \(queuedCount) waiting."
            } else {
                summary = "\(completed) " + (completed == 1 ? "audiobook ready" : "audiobooks ready") + (failed > 0 ? "; \(failed) failed. Select a failed row to retry." : "")
            }
            isRunning = false; task = nil
            persist()
            onCompletion?(summary)
        }
    }

    private func receive(_ update: ExportProgress, id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state == .running else { return }
        jobs[index].progress = update.fraction; jobs[index].message = update.message
        activeProgress = update
        // The total grows as books are added during the run.
        batchProgress = (Double(batchFinished) + update.fraction) / Double(max(1, batchFinished + queuedCount + 1))
        summary = progressSummary(jobs[index].title)
    }

    private func progressSummary(_ title: String) -> String {
        "Converting \(batchFinished + 1) of \(batchFinished + queuedCount + 1): \(title)"
    }

    private func updateJob(_ id: UUID, _ change: (inout AudiobookJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }

    public func cancelAndPause() {
        guard isRunning else { return }
        pauseRequested = true; summary = "Cancelling the current audiobook…"
        runner?.cancel(); task?.cancel()
    }

    public func waitUntilFinished() async { await task?.value }
    public func shutdown() async { cancelAndPause(); await task?.value }

    public static func uniqueDestination(title: String, folder: URL, mode: ExportMode) -> URL {
        let name = FileNames.safe(title)
        var suffix = 1
        while true {
            let stem = suffix == 1 ? name : "\(name) (\(suffix))"
            let url = folder.appendingPathComponent(mode == .chapters ? stem : stem + "." + mode.fileExtension, isDirectory: mode == .chapters)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            suffix += 1
        }
    }
}
