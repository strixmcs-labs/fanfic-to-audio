import SwiftUI
import AudiobookCore

/// The queue's one bright moment: the book being narrated, its cover, and its chapters filling in.
struct NowNarratingPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var queue: AudiobookQueue

    var body: some View {
        if queue.isRunning, let active = queue.activeBook, let job = queue.jobs.first(where: { $0.id == active.id }) {
            let chapters = model.chaptersBeingNarrated()
            let progress = queue.activeProgress
            let total = progress?.chapters ?? chapters.count
            let current = (progress?.chapter ?? 1) - 1
            HStack(alignment: .top, spacing: 28) {
                BookCover(title: active.book.title, author: active.book.author,
                          image: model.book?.source == active.book.source ? model.coverImage : nil)
                    .frame(width: 148, height: 210)
                VStack(alignment: .leading, spacing: AppTheme.space4) {
                    HStack(alignment: .top, spacing: AppTheme.space3) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Now narrating").font(.caption).foregroundStyle(.secondary)
                            Text(active.book.title).font(.system(size: 20, weight: .semibold)).lineLimit(2).textSelection(.enabled)
                            if !active.book.author.isEmpty { Text(active.book.author).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        LabsBadge(label: "Converting", tone: .accent)
                    }
                    VStack(alignment: .leading, spacing: AppTheme.space2) {
                        Text(progressLine(progress, chapters: chapters, job: job))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                        ChapterTicks(total: total, current: current)
                    }
                    HStack(alignment: .top, spacing: AppTheme.space4) {
                        figure("Progress", "\(Int((job.progress * 100).rounded()))%")
                        figure("Full book", model.listeningTime(for: chapters, preset: job.narration))
                        figure("Words", chapters.reduce(0) { $0 + $1.wordCount }.formatted())
                    }
                    Divider()
                    HStack(spacing: AppTheme.space3) {
                        Text(job.narration?.displaySummary ?? "").font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button("Cancel & Pause Queue", action: queue.cancelAndPause)
                    }
                }
            }
            .padding(AppTheme.space6).frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.card, in: RoundedRectangle(cornerRadius: AppTheme.radiusMedium))
            .overlay(RoundedRectangle(cornerRadius: AppTheme.radiusMedium).stroke(AppTheme.line, lineWidth: 1))
        }
    }

    /// "Chapter 7 of 14 · A Mad Tea-Party · passage 2 of 3", or the job's status before narration starts.
    private func progressLine(_ progress: ExportProgress?, chapters: [BookChapter], job: AudiobookJob) -> String {
        guard let progress, let chapter = progress.chapter, let count = progress.chapters else { return job.message }
        var parts = ["Chapter \(chapter) of \(count)"]
        if chapters.indices.contains(chapter - 1) { parts.append(chapters[chapter - 1].title) }
        if let passage = progress.passage, let passages = progress.passages { parts.append("passage \(passage) of \(passages)") }
        return parts.joined(separator: " · ")
    }

    private func figure(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 18, weight: .medium).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A book cover with a spine, light, and page edge. The art gradient is the one gradient the
/// StrixMCS standard allows, for book artwork only; there is no drop shadow.
struct BookCover: View {
    let title: String
    let author: String
    let image: NSImage?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: width, height: geo.size.height).clipped()
                } else {
                    AppTheme.bookGradient
                    VStack(alignment: .leading, spacing: 0) {
                        if width > 100 { Text(author).font(.system(size: 11)).opacity(0.85).lineLimit(2) }
                        Spacer(minLength: 4)
                        Text(title).font(.system(size: width > 100 ? 16 : 10, weight: .semibold)).lineLimit(width > 100 ? 5 : 4)
                        Spacer(minLength: 4)
                        if width > 100 { Rectangle().fill(Color.white.opacity(0.75)).frame(width: 28, height: 1) }
                    }
                    .foregroundStyle(Color(white: 0.97))
                    .padding(.leading, max(8, width * 0.16)).padding(.trailing, max(6, width * 0.1)).padding(.vertical, max(8, width * 0.11))
                }
                // Spine: darker at the hinge, a faint highlight, then a shadow where the board turns.
                LinearGradient(stops: [.init(color: .black.opacity(0.34), location: 0), .init(color: .white.opacity(0.06), location: 0.6),
                                       .init(color: .black.opacity(0.12), location: 1)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: max(5, width * 0.08))
                LinearGradient(colors: [.white.opacity(0.12), .clear], startPoint: .topLeading, endPoint: .center)
                // Page edge along the fore-edge.
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Rectangle().fill(Color.black.opacity(0.2)).frame(width: 1)
                    Rectangle().fill(Color(white: 0.86)).frame(width: max(2, width * 0.027))
                }
            }
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: AppTheme.radiusSmall, bottomLeadingRadius: AppTheme.radiusSmall,
                                              bottomTrailingRadius: AppTheme.radiusMedium, topTrailingRadius: AppTheme.radiusMedium))
        }
        .accessibilityElement().accessibilityLabel(author.isEmpty ? "Cover: \(title)" : "Cover: \(title) by \(author)")
    }
}

/// The signature detail: one tick per section, filled as each is narrated. Used only where
/// narration progress is shown.
struct ChapterTicks: View {
    let total: Int
    let current: Int

    var body: some View {
        Canvas { context, size in
            guard total > 0 else { return }
            let gap: CGFloat = total <= 40 ? 3 : (total <= 120 ? 1 : 0)
            let width = max(0.5, (size.width - gap * CGFloat(total - 1)) / CGFloat(total))
            for index in 0..<total {
                let rect = CGRect(x: CGFloat(index) * (width + gap), y: 0, width: width, height: size.height)
                let color = index < current ? AppTheme.tickDone : (index == current ? AppTheme.oxblood : AppTheme.lineStrong)
                context.fill(Path(rect), with: .color(color))
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel(total > 0 ? "Section \(min(current + 1, total)) of \(total) is being narrated" : "Preparing sections")
    }
}
