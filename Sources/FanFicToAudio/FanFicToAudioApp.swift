import SwiftUI
import AppKit
import AudiobookCore

@main
struct FanFicToAudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @StateObject private var download = DownloadModel()
    var body: some Scene {
        Window("FanFic to Audio", id: "main") {
            WorkflowView(audio: model, download: download)
                .frame(minWidth: 1060, minHeight: 700)
                .task {
                    delegate.model = model
                    delegate.download = download
                    await model.loadVoices()
                }
        }
        .defaultSize(width: 1180, height: 820)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About FanFic to Audio", action: LabsCredits.showAboutPanel)
            }
            CommandGroup(replacing: .newItem) {
                Button("Open EPUB…", action: model.chooseEPUB).keyboardShortcut("o").disabled(model.busy)
                Button("Add EPUBs to Audiobook Queue…", action: model.chooseQueuedEPUBs)
                    .keyboardShortcut("o", modifiers: [.command, .shift]).disabled(!model.canAddToQueue)
            }
            CommandGroup(after: .importExport) {
                Button("Export Audiobook…", action: model.chooseDestinationAndExport)
                    .keyboardShortcut("e", modifiers: [.command, .shift]).disabled(!model.canExport)
            }
            CommandGroup(after: .help) {
                Button("FanFicFare Project") { NSWorkspace.shared.open(LabsCredits.fanFicFareURL) }
            }
        }
        Settings {
            VStack(alignment: .leading, spacing: 16) {
                Text("Audiobook encoder").font(.title2.bold())
                Text("macOS voices narrate the EPUBs. A standalone FFmpeg encoder is bundled for MP3 and M4B output.")
                Text(model.ffmpeg?.path ?? "FFmpeg was not found.").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Button("Choose FFmpeg…", action: model.chooseFFmpeg).disabled(model.busy)
                Link("FFmpeg installation options", destination: URL(string: "https://ffmpeg.org/download.html#build-mac")!)
                Divider()
                Text("Additional voices").font(.headline)
                Text("Download voices in System Settings → Accessibility → Read & Speak (called Spoken Content on earlier macOS versions). Then refresh the voice list.")
                Button("Refresh Voices") { Task { await model.loadVoices() } }.disabled(model.busy || model.isPreviewing)
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text(LabsCredits.byline).font(.caption.weight(.medium))
                    Text(LabsCredits.upstream).font(.caption).foregroundStyle(.secondary)
                    Text(LabsCredits.independence).font(.caption).foregroundStyle(.secondary)
                    Link("FanFicFare on GitHub", destination: LabsCredits.fanFicFareURL).font(.caption)
                }
            }
            .padding(24).frame(width: 470).background(AppTheme.background).tint(AppTheme.oxblood)
            .buttonStyle(LabsButtonStyle())
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel? {
        didSet { if let model, !pendingOpen.isEmpty { model.openFiles(pendingOpen); pendingOpen = [] } }
    }
    weak var download: DownloadModel?
    // Files opened from Finder can arrive before the window has connected the model.
    private var pendingOpen: [URL] = []
    func application(_ application: NSApplication, open urls: [URL]) {
        if let model { model.openFiles(urls) } else { pendingOpen += urls }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task {
            await download?.shutdown()
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Publication credits for a StrixMCS Labs app: the Labs byline, then upstream credit beneath it,
/// naming the project and its authors (public name, then handle) without implying endorsement.
/// The seal and the Labs lockup appear only on absolute black, so the app shows the text forms.
enum LabsCredits {
    static let byline = "StrixMCS Labs · Dr. Matt Booth"
    /// The bundled FanFicFare release; a test keeps it equal to the pin in requirements-build.txt.
    static let fanFicFareVersion = "4.63.0"
    static let upstream = "Story downloading is powered by FanFicFare \(fanFicFareVersion), by Jim Miller (JimmXinu) and the FanFicFare contributors, under the Apache License 2.0."
    static let independence = "FanFic to Audio is an independent application, not an official FanFicFare release."
    static let fanFicFareURL = URL(string: "https://github.com/JimmXinu/FanFicFare")!
    static let labsGitHubURL = URL(string: "https://github.com/strixmcs-labs")!

    /// The About panel shows the Labs byline and the StrixMCS Labs GitHub link; FanFicFare is
    /// credited in Download by Link, Settings, the Help menu, and the documentation.
    @MainActor static func showAboutPanel() {
        let credits = NSMutableAttributedString(string: byline + "\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor])
        credits.append(NSAttributedString(string: "github.com/strixmcs-labs",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .link: labsGitHubURL]))
        let centered = NSMutableParagraphStyle(); centered.alignment = .center
        credits.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate()
    }
}
