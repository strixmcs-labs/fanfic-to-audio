import SwiftUI

struct WorkflowView: View {
    @ObservedObject var audio: AppModel
    @ObservedObject var download: DownloadModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Label("FanFic to Audio", systemImage: "book").font(.headline)
                Spacer()
                Picker("Workflow", selection: $audio.stage) {
                    Text("1 · Download by Link").tag(0)
                    Text("2 · Create Audiobook").tag(1)
                }.pickerStyle(.segmented).frame(width: 370)
                Spacer()
                Button("Open EPUB…") { audio.chooseEPUB() }.disabled(audio.busy)
            }.padding(.horizontal, 24).padding(.vertical, 14)
            Divider()
            if let notice = audio.queueNotice { queueNoticeBar(notice) }
            if audio.stage == 0 {
                // Downloads stay available while audio converts; finished books join the queue.
                DownloadView(model: download, canOpenBooks: !audio.busy) { url in open(url) }
            } else {
                ContentView(model: audio)
            }
        }
        .background(AppTheme.background).tint(AppTheme.oxblood)
        // Every button follows the Labs component rules unless a view picks another variant.
        .buttonStyle(LabsButtonStyle())
        .onChange(of: download.isRunning) { _, value in
            audio.downloadInProgress = value
            if value { audio.stopPreview() }
        }
        .onChange(of: download.finishedBook) { _, book in
            // A running queue takes each book as it downloads, so it converts it before stopping.
            guard let book, audio.audiobookQueue.isRunning else { return }
            audio.addToAudiobookQueue([book.url]); download.markQueued(book.url)
        }
        .onChange(of: download.readyURLs) { _, urls in
            audio.downloadInProgress = download.isRunning
            if !urls.isEmpty { audio.addToAudiobookQueue(urls) }
        }
    }

    private func queueNoticeBar(_ notice: String) -> some View {
        // The screen's one oxblood left rule marks this notice.
        HStack(spacing: 10) {
            Image(systemName: "text.badge.plus").foregroundStyle(AppTheme.oxblood).accessibilityHidden(true)
            Text(notice).font(.callout)
            Spacer()
            Button("Show Queue") { audio.stage = 1; audio.pane = .queue; audio.queueNotice = nil }
                .buttonStyle(LabsButtonStyle(variant: .ghost))
            Button("Dismiss") { audio.queueNotice = nil }.buttonStyle(LabsButtonStyle(variant: .ghost))
        }
        .padding(.leading, 21).padding(.trailing, 24).padding(.vertical, 8)
        .background(AppTheme.accentWash)
        .overlay(alignment: .leading) { Rectangle().fill(AppTheme.structure).frame(width: 3) }
        .overlay(alignment: .bottom) { Divider() }
    }

    private func open(_ url: URL) {
        guard !audio.busy else { return }
        audio.stage = 1
        audio.loadBook(url)
    }
}
