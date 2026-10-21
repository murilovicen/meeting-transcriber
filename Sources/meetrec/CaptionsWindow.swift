import AppKit
import SwiftUI

/// Floating, non-activating caption panel that stays above every window (and full-screen calls).
@MainActor
final class CaptionsWindow {
    private var panel: NSPanel?
    let captions: Captions
    var language: () -> String = { "" }
    var onAsk: (String) -> Void = { _ in }

    init(captions: Captions) { self.captions = captions }

    var isVisible: Bool { panel?.isVisible ?? false }

    func show() {
        if panel == nil { panel = makePanel() }
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        let size = NSSize(width: 640, height: 230)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: screen.midX - size.width / 2, y: screen.minY + 40)
        let p = NSPanel(contentRect: NSRect(origin: origin, size: size),
                        styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView, .utilityWindow],
                        backing: .buffered, defer: false)
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.backgroundColor = .clear
        p.setFrameAutosaveName("MeetRecCaptions")
        p.contentView = NSHostingView(rootView: CaptionsView(captions: captions, language: language, ask: { [weak self] in self?.onAsk($0) }))
        return p
    }
}

struct CaptionsView: View {
    @ObservedObject var captions: Captions
    let language: () -> String
    let ask: (String) -> Void
    @State private var hovered: UUID?

    /// The last ~2 minutes, as "Speaker: text" lines.
    private var recent: String {
        let cutoff = Date().addingTimeInterval(-120)
        var lines = captions.lines.filter { $0.updated > cutoff }.map { "\($0.speaker): \($0.text)" }
        for s in ["Others", "Me"] { if let p = captions.partial[s], !p.isEmpty { lines.append("\(s): \(p)") } }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                Text("Live").font(.system(size: 12, weight: .semibold))
                Text(language()).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                if !captions.status.isEmpty {
                    Text(captions.status).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Button {
                    ask(recent)
                } label: {
                    Label("Ask Claude", systemImage: "sparkles").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
                .disabled(recent.isEmpty)
                .help("Open a Claude session about the last couple of minutes")
            }
            .padding(.leading, 64)  // clear the traffic-light button

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(captions.lines) { line in
                            row(line.speaker, Text(line.text))
                                .overlay(alignment: .topTrailing) {
                                    if hovered == line.id {
                                        Button { ask("\(line.speaker): \(line.text)") } label: {
                                            Image(systemName: "sparkles").font(.system(size: 13))
                                        }
                                        .buttonStyle(.borderless)
                                        .help("Ask Claude about this")
                                    }
                                }
                                .onHover { hovered = $0 ? line.id : (hovered == line.id ? nil : hovered) }
                        }
                        ForEach(["Others", "Me"], id: \.self) { s in
                            if let p = captions.partial[s], !p.isEmpty {
                                row(s, Text(p).foregroundColor(.secondary))
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: captions.lines.count) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: captions.partial) { proxy.scrollTo("bottom", anchor: .bottom) }
            }

            if captions.lines.isEmpty && captions.partial.values.allSatisfy(\.isEmpty) {
                Text("Listening…").font(.system(size: 15)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(VisualEffect().ignoresSafeArea())
    }

    private func row(_ speaker: String, _ text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(speaker)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(speaker == "Me" ? Color(red: 0.36, green: 0.62, blue: 1) : Color(red: 1, green: 0.42, blue: 0.55))
                .frame(width: 48, alignment: .trailing)
            text.font(.system(size: 17)).textSelection(.enabled)
        }
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}
