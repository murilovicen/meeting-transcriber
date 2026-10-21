import AppKit
import SwiftUI

/// Opens a new Claude desktop Code session on a meeting folder with the analysis prompt prefilled.
/// Documented deep link: claude://code/new?q=<prompt>&folder=<path> (Desktop confirms the folder).
func openInClaude(_ dir: URL, excerpt: String? = nil) {
    let prompt = excerpt.map(livePrompt) ?? """
    Go through the meeting in this folder. transcript.md is the transcript; speaker names come from \
    local voice matching and can be wrong, and "Me" is me.
    Lead with decisions and action items (with owners), then open questions and risks, then a short summary.
    Don't create tickets or send messages without asking me first.
    """
    launchClaude(prompt: prompt, folder: dir)
}

/// For "ask Claude about what was just said" during a call.
private func livePrompt(_ excerpt: String) -> String {
    let quoted = String(excerpt.suffix(8000)).split(separator: "\n").map { "> \($0)" }.joined(separator: "\n")
    return """
    I'm in a meeting right now (it's being recorded in this folder; the full transcript comes after the call). \
    This was just said:

    \(quoted)

    Help me with it: explain, fact-check, or suggest what to answer, briefly. \
    Don't create tickets or send messages without asking me first.
    """
}

private func launchClaude(prompt: String, folder dir: URL) {
    var c = URLComponents()
    c.scheme = "claude"
    c.host = "code"
    c.path = "/new"
    c.queryItems = [URLQueryItem(name: "q", value: prompt), URLQueryItem(name: "folder", value: dir.path)]
    guard let url = c.url else { return }
    log("  opening Claude for \(dir.lastPathComponent)")
    NSWorkspace.shared.open(url)
}

/// Small non-blocking "analyze with Claude?" prompt shown after each transcript.
@MainActor
final class AnalyzePrompt {
    private var window: NSWindow?

    func ask(_ dir: URL) {
        window?.close()
        let meeting = MeetingSpeakers.load(dir)
        let people = meeting?.speakers.filter { $0.seconds >= 3 }.map(\.label) ?? []
        let view = AnalyzePromptView(title: dir.lastPathComponent, people: people) { [weak self] analyze in
            self?.window?.close()
            self?.window = nil
            if analyze { openInClaude(dir) }
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 150),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "MeetRec"
        w.contentView = NSHostingView(rootView: view)
        w.isReleasedWhenClosed = false
        w.level = .floating
        if let screen = NSScreen.main?.visibleFrame {
            w.setFrameTopLeftPoint(NSPoint(x: screen.maxX - 420, y: screen.maxY - 20))
        }
        window = w
        w.orderFrontRegardless()
    }
}

struct AnalyzePromptView: View {
    let title: String
    let people: [String]
    let done: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Transcript ready").font(.headline)
            Text(people.isEmpty ? title : "\(title) · with \(people.joined(separator: ", "))")
                .font(.callout).foregroundStyle(.secondary).lineLimit(2)
            Text("Analyzing sends the transcript text to Claude. Audio and voices stay on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Not now") { done(false) }
                Button("Analyze with Claude") { done(true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 400)
    }
}
