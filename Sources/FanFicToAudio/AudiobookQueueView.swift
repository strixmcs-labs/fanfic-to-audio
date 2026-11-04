import SwiftUI
import UniformTypeIdentifiers
import AudiobookCore

struct AudiobookQueueView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var queue: AudiobookQueue
    private let accent = AppTheme.oxblood

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if queue.jobs.isEmpty {
                emptyState
            } else {
                // Rows flow in the page's scroll view, so the list grows with the window.
                LazyVStack(spacing: 4) {
                    ForEach(Array(queue.jobs.enumerated()), id: \.element.id) { index, job in row(job, index: index) }
                }
                .padding(.horizontal, AppTheme.space2).padding(.bottom, AppTheme.space2)
                if let job = queue.jobs.first(where: { $0.id == model.selectedQueueJob }) {
                    Divider()
                    selectedBookToolbar(job)
                }
            }
            if queue.queuedCount >= 2 || !model.seriesJobs.isEmpty {
                Divider()
                seriesSection
            }
            Divider()
            footer
        }
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: AppTheme.radiusMedium))
        .overlay(RoundedRectangle(cornerRadius: AppTheme.radiusMedium).stroke(AppTheme.line, lineWidth: 1))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.space3) {
            Text("Queue").font(.system(size: 15, weight: .semibold))
            Text(counts).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            if model.book != nil {
                Button("Add Open Book", action: model.queueCurrentBook)
                    .disabled(model.busy || model.selectedChapters.isEmpty)
            }
            Button { model.chooseQueuedEPUBs() } label: { Label("Add EPUBs…", systemImage: "plus") }
                .disabled(!model.canAddToQueue)
        }
        .padding(.leading, AppTheme.space5).padding(.trailing, AppTheme.space4).padding(.vertical, AppTheme.space4)
    }

    /// "1 converting · 2 waiting · 1 failed · 1 done", leaving out states with no books.
    private var counts: String {
        let tally: [(String, Int)] = [("converting", queue.jobs.filter { $0.state == .running }.count),
                                      ("waiting", queue.queuedCount),
                                      ("failed", queue.jobs.filter { $0.state == .failed }.count),
                                      ("paused", queue.jobs.filter { $0.state == .cancelled }.count),
                                      ("done", queue.jobs.filter { $0.state == .done }.count)]
        return tally.filter { $0.1 > 0 }.map { "\($0.1) \($0.0)" }.joined(separator: " · ")
    }

    private var emptyState: some View {
        HStack(spacing: AppTheme.space4) {
            Image(systemName: "books.vertical").font(.system(size: 28, weight: .light)).foregroundStyle(accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Make audiobooks in bulk").font(.callout.weight(.medium))
                Text("Each book gets its own MP3, M4B, or chapter folder. Existing audiobooks are preserved.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, AppTheme.space5).padding(.bottom, AppTheme.space5)
    }

    private func row(_ job: AudiobookJob, index: Int) -> some View {
        HStack(alignment: .top, spacing: AppTheme.space2) {
            Toggle("Include \(job.title) in combined series", isOn: Binding(
                get: { model.seriesJobIDs.contains(job.id) },
                set: { if $0 { model.seriesJobIDs.insert(job.id) } else { model.seriesJobIDs.remove(job.id) } }))
                .labelsHidden().toggleStyle(.checkbox).padding(.top, 14).padding(.leading, AppTheme.space2)
                .disabled(model.busy || job.state != .queued)
            Button { model.selectedQueueJob = job.id } label: {
                HStack(alignment: .top, spacing: AppTheme.space3) {
                    Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.title).font(.system(size: 14, weight: .medium)).lineLimit(2)
                        if !job.author.isEmpty { Text(job.author).font(.caption).foregroundStyle(.secondary) }
                        if let preset = job.narration {
                            Text(preset.displaySummary).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                        }
                        // No status colors: a failure reads in full-strength text beside an accent badge.
                        Text(job.message).font(.caption).foregroundStyle(job.state == .failed ? AppTheme.text : Color.secondary)
                            .lineLimit(3).padding(.top, 2)
                        if job.state == .running { ProgressView(value: job.progress).padding(.top, 4) }
                    }
                    Spacer(minLength: AppTheme.space2)
                    LabsBadge(label: job.state.rawValue, tone: [.running, .failed].contains(job.state) ? .accent : .neutral)
                }
                .padding(AppTheme.space3).frame(maxWidth: .infinity, alignment: .leading)
                .labsRow(selected: model.selectedQueueJob == job.id)
                .contentShape(RoundedRectangle(cornerRadius: AppTheme.radiusMedium))
            }
            .buttonStyle(.plain).disabled(!(model.canSelectQueue || queue.isRunning))
            .onDrag { NSItemProvider(object: job.id.uuidString as NSString) }
            .onDrop(of: [UTType.text], isTargeted: nil) { providers in
                guard model.canAddToQueue, let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    guard let text = object as? String, let id = UUID(uuidString: text) else { return }
                    Task { @MainActor in if model.canAddToQueue { queue.move(id, before: job.id) } }
                }
                return true
            }
        }
    }

    /// The everyday actions stay visible; rarer ones live under More.
    private func selectedBookToolbar(_ job: AudiobookJob) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.space3) {
            HStack(spacing: AppTheme.space1) {
                Text(job.title).font(.caption).foregroundStyle(.secondary).lineLimit(1).padding(.trailing, AppTheme.space2)
                Button { queue.move(job.id, by: -1) } label: { Label("Move Up", systemImage: "arrow.up") }
                    .buttonStyle(LabsButtonStyle(variant: .ghost))
                    .disabled(!model.canAddToQueue || !queue.canMove(job.id, by: -1))
                Button { queue.move(job.id, by: 1) } label: { Label("Move Down", systemImage: "arrow.down") }
                    .buttonStyle(LabsButtonStyle(variant: .ghost))
                    .disabled(!model.canAddToQueue || !queue.canMove(job.id, by: 1))
                Button {
                    queue.remove(job.id); model.seriesJobIDs.remove(job.id)
                    model.selectedQueueJob = queue.jobs.first?.id
                } label: { Label("Remove", systemImage: "trash") }
                    .buttonStyle(LabsButtonStyle(variant: .ghost))
                    .disabled(!model.canAddToQueue || queue.isLocked(job.id))
                Spacer()
                if [.failed, .cancelled].contains(job.state) {
                    Button { queue.retry(job.id) } label: { Label("Retry", systemImage: "arrow.clockwise") }
                        .disabled(!model.canAddToQueue)
                }
                if job.state == .done, job.output != nil {
                    Button("Show in Finder", action: model.revealQueuedAudiobook)
                }
                Menu {
                    Button("Save Current Settings & Sections for This Book", action: model.saveSelectedJobSettings)
                        .disabled(job.state == .done || model.busy || !model.isOpen(job) || model.selectedChapters.isEmpty)
                    Button("Discard Saved Passages") { queue.discardCheckpoint(job.id) }
                        .disabled(queue.isLocked(job.id))
                    Divider()
                    Button("Clear Completed", action: model.clearCompletedAudiobooks).disabled(!model.canAddToQueue)
                } label: { Label("More", systemImage: "ellipsis") }
                    .menuStyle(.button).fixedSize()
                    .accessibilityLabel("More actions for \(job.title)")
            }
            if job.state != .done { savedSettings(job) }
        }
        .padding(.leading, AppTheme.space5).padding(.trailing, AppTheme.space4).padding(.vertical, AppTheme.space3)
    }

    /// A book with saved settings ignores the Voice & Text controls; say so plainly.
    @ViewBuilder private func savedSettings(_ job: AudiobookJob) -> some View {
        if let preset = job.narration {
            let matches = preset.isEquivalent(to: model.presetFromControls())
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.space2) {
                Image(systemName: "slider.horizontal.3").foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Saved for this book: \(preset.displaySummary)").font(.caption)
                    if !matches {
                        Text("This book is narrated with its saved settings, not the current Voice & Text settings.")
                            .font(.caption.weight(.medium))
                    }
                }
                Spacer()
                Button("Use in Controls") { model.useInControls(preset) }.disabled(model.busy || matches)
                Button("Clear Saved Settings") { queue.clearNarration(job.id) }.disabled(queue.isLocked(job.id))
            }
        } else {
            Text("This book uses the Voice & Text settings in effect when the queue starts.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var seriesSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.space3) {
            HStack {
                Text("Combine a series").font(.callout.weight(.medium))
                Spacer()
                Button("Select Waiting EPUBs") { model.seriesJobIDs = Set(queue.jobs.filter { $0.state == .queued }.map(\.id)) }.disabled(model.busy)
                Button("Clear Selection") { model.seriesJobIDs = [] }.disabled(model.busy)
            }
            Text("Check the books to combine, move them into reading order, and give the series a title. The saved EPUB preserves chapters, images, and styles; its queue entry creates the series audiobook.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Series title", text: $model.seriesTitle).textFieldStyle(.roundedBorder)
                Text("\(model.seriesJobs.count) books").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button(model.isCombining ? "Combining…" : "Combine Selected EPUBs…", action: model.combineSeries)
                    .disabled(model.busy || model.seriesJobs.count < 2 || model.seriesTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.disabled(model.busy)
        }
        .padding(.horizontal, AppTheme.space5).padding(.vertical, AppTheme.space4)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: AppTheme.space3) {
            HStack(spacing: AppTheme.space2) {
                Text("Save to").font(.caption).foregroundStyle(.secondary)
                Text(model.audiobookFolder.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "Chosen when the queue starts")
                    .font(.caption.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle).id(model.audiobookFolder)
                Button("Change…", action: model.chooseAudiobookFolder).buttonStyle(LabsButtonStyle(variant: .ghost)).disabled(model.busy)
                if model.audiobookFolder != nil {
                    Button("Clear") { model.audiobookFolder = nil }.buttonStyle(LabsButtonStyle(variant: .ghost)).disabled(model.busy)
                }
                Spacer()
            }
            if model.ffmpeg == nil {
                HStack {
                    Text("Select FFmpeg to enable audiobook conversion.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose FFmpeg…", action: model.chooseFFmpeg).disabled(model.busy)
                }
            }
            if let error = queue.persistenceError {
                Label { Text(error).font(.caption).textSelection(.enabled) } icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(accent) }
            }
            if queue.isRunning { ProgressView(value: queue.batchProgress) }
            HStack {
                Text(queue.summary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if queue.isRunning {
                    Button("Cancel & Pause Queue", action: queue.cancelAndPause)
                } else {
                    Button(model.audiobookFolder == nil ? "Create Queued Audiobooks…" : "Start Queue", action: model.startAudiobookQueue)
                        .buttonStyle(LabsButtonStyle(variant: .primary, large: true)).disabled(!model.canStartQueue)
                }
            }
            Text("Waiting books can be added, moved, retried, or removed while the queue runs. Only the book being narrated is locked. Retry resumes completed passages when the text and settings match.")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: 640, alignment: .leading)
        }
        .padding(.leading, AppTheme.space5).padding(.trailing, AppTheme.space4).padding(.vertical, AppTheme.space4)
    }
}
