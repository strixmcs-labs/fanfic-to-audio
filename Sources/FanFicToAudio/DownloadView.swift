import SwiftUI
import DownloadCore

struct DownloadView: View {
    @ObservedObject var model: DownloadModel
    /// False while audio converts; finished books still join the queue automatically.
    let canOpenBooks: Bool
    let openBook: (URL) -> Void
    private let accent = AppTheme.oxblood

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Download by link").font(.system(size: 28, weight: .semibold))
                    Text("Paste a story page or an EPUB download link. Finished downloads join the audiobook queue, including while a conversion runs.").foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Story or EPUB links").font(.headline)
                        Text("Paste one URL per line. Story chapter ranges such as [1-5] are supported.").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $model.links)
                            .font(.system(.body, design: .monospaced)).scrollContentBackground(.hidden)
                            .padding(8).frame(minHeight: 125, maxHeight: 160)
                            .background(AppTheme.background, in: RoundedRectangle(cornerRadius: AppTheme.radius))
                            .overlay(RoundedRectangle(cornerRadius: AppTheme.radius).stroke(AppTheme.lineStrong, lineWidth: 1))
                            .accessibilityLabel("Story or EPUB URLs, one per line")
                        HStack {
                            Picker("Action", selection: $model.selectedOperation) {
                                Text("Download by Link").tag("download")
                                Text("Preview story").tag("preview")
                                Text("Find links on a page").tag("extract")
                            }.frame(maxWidth: 290)
                            if model.selectedOperation == "download" {
                                Picker("Link type", selection: $model.sourceKind) {
                                    Text("Detect automatically").tag("auto")
                                    Text("Story page").tag("story")
                                    Text("Direct EPUB").tag("epub")
                                }
                            }
                            Spacer()
                        }
                        HStack {
                            Button("Add to Queue") { model.addLinks() }.disabled(model.links.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Spacer()
                            Button(model.selectedOperation == "download" ? "Download & Prepare Audiobook" : "Run Action") { model.addLinks(startImmediately: true) }
                                .buttonStyle(LabsButtonStyle(variant: .primary, large: true))
                                .disabled(model.isRunning || model.links.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).labsCard()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Download preferences").font(.headline)
                        Text("Save EPUBs to").font(.caption).foregroundStyle(.secondary)
                        Text(model.output.path).font(.caption).textSelection(.enabled).lineLimit(3)
                        Button("Choose Folder…", action: model.chooseOutput)
                        Divider()
                        Text("Site settings and login").font(.subheadline.weight(.medium))
                        Text(model.ini.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Default site settings")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Choose personal.ini…", action: model.chooseINI)
                            if model.ini != nil { Button("Clear") { model.ini = nil } }
                        }
                        Toggle("Allow adult stories", isOn: $model.adult).font(.callout)
                        Text("Login details come from the selected INI. This choice applies to new and retried jobs.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(width: 230, alignment: .leading).labsCard()
                }
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Story queue").font(.headline)
                        Spacer()
                        Button("Update Existing EPUBs…", action: model.updateEPUBs).disabled(model.isRunning)
                        if model.isRunning {
                            Button(model.isFinalizing ? "Saving EPUB…" : "Cancel & Pause Queue", action: model.cancel).disabled(model.isFinalizing)
                        } else {
                            Button("Start Queue", action: model.start).disabled(!model.hasQueued)
                        }
                    }
                    if model.jobs.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "arrow.down.document").font(.system(size: 32)).foregroundStyle(accent)
                            Text("Downloaded stories appear here.").font(.headline)
                            Text("For an EPUB already on this Mac, use Open EPUB… in the toolbar.")
                                .font(.callout).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(32)
                    } else {
                        ForEach(model.jobs) { job in
                            Button { model.selected = job.id } label: {
                                HStack(alignment: .top, spacing: 14) {
                                    Image(systemName: job.path != nil ? "book.closed" : job.state == .failed ? "exclamationmark.circle" : "link")
                                        .font(.system(size: 20, weight: .light)).foregroundStyle(accent).frame(width: 32).padding(.top, 4)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(job.title).font(.headline).lineLimit(2).textSelection(.enabled)
                                        if !job.author.isEmpty { Text(job.author).font(.callout).foregroundStyle(.secondary) }
                                        if !job.wordCount.isEmpty { Text(job.wordCount).font(.caption).foregroundStyle(.secondary) }
                                        Text(job.message.isEmpty ? job.request.operation.capitalized : job.message)
                                            .font(.caption).foregroundStyle(job.state == .failed ? AppTheme.text : Color.secondary).lineLimit(4)
                                        if job.state == .running {
                                            if let progress = job.progress { ProgressView(value: progress, total: 100) }
                                            else { ProgressView().controlSize(.small) }
                                        }
                                    }
                                    Spacer()
                                    LabsBadge(label: job.state.rawValue, tone: [.running, .failed].contains(job.state) ? .accent : .neutral)
                                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                    .labsRow(selected: model.selected == job.id)
                                    .contentShape(RoundedRectangle(cornerRadius: AppTheme.radiusMedium))
                            }.buttonStyle(.plain)
                        }
                        if let selected = model.selectedJob {
                            HStack {
                                if let path = selected.path {
                                    Button("Make Audiobook") { openBook(path) }.buttonStyle(.borderedProminent).disabled(model.isRunning || !canOpenBooks)
                                        .help(canOpenBooks ? "Open this EPUB in Create Audiobook" : "Already in the audiobook queue; available after the current conversion")
                                    Button("Show EPUB in Finder", action: model.revealSelected)
                                }
                                if selected.state.canRetry {
                                    Button("Retry Selected", action: model.retrySelected).disabled(model.isRunning)
                                }
                                Spacer()
                                Button("Clear Finished") { model.jobs.removeAll { $0.state.isFinished } }
                                    .disabled(model.isRunning)
                            }
                            if let backup = selected.backup {
                                Text("Original EPUB backed up to \(backup)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                }.labsCard()
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(LabsCredits.upstream).font(.caption.weight(.medium))
                        Link("FanFicFare on GitHub", destination: LabsCredits.fanFicFareURL).font(.caption)
                    }
                    Text("FanFicFare handles supported story sites and their access requirements. Direct EPUB links are downloaded and validated before saving. EPUBs stay in the chosen folder. Voices and AI speech providers are set in Create Audiobook.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(32).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
        }
        .tint(accent)
        .alert("Unable to complete this action", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
}
