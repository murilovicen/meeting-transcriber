import AppKit
import AVFoundation
import SwiftUI

/// After a meeting: "who was Speaker 1?" — play a clip, type a name once, and MeetRec remembers the voice.
@MainActor
final class SpeakerNamingWindow {
    private var window: NSWindow?

    func show(dir: URL, onDone: @escaping (_ saved: Bool) -> Void) {
        guard let meeting = MeetingSpeakers.load(dir) else { return }
        let view = SpeakerNamingView(
            dir: dir,
            speakers: meeting.speakers.filter { $0.seconds >= 3 }.sorted { !$0.known && $1.known },
            segments: meeting.segments,
            quotes: Self.quotes(dir),
            knownNames: VoiceLibrary.load().names,
            close: { [weak self] saved in
                self?.window?.close()
                self?.window = nil
                onDone(saved)
            })
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Who's who? — \(dir.lastPathComponent)"
        w.contentView = NSHostingView(rootView: view)
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    /// The two longest things each voice said, so you can tell who it was.
    private static func quotes(_ dir: URL) -> [String: [String]] {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("turns.json")),
              let turns = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
        var bySpeaker: [String: [String]] = [:]
        for t in turns {
            guard let id = t["speaker_id"] as? String, let text = t["text"] as? String else { continue }
            bySpeaker[id, default: []].append(text)
        }
        return bySpeaker.mapValues { texts in
            texts.sorted { $0.count > $1.count }.prefix(2).map { $0.count > 160 ? String($0.prefix(160)) + "…" : $0 }
        }
    }
}

@MainActor
final class ClipPlayer: ObservableObject {
    @Published var playing: String?
    private var player: AVAudioPlayer?
    private var stopTask: Task<Void, Never>?

    func toggle(id: String, file: URL, start: Double, duration: Double) {
        if playing == id { stop(); return }
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: file) else { return }
        p.currentTime = start
        p.play()
        player = p
        playing = id
        stopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            if !Task.isCancelled { self?.stop() }
        }
    }

    func stop() {
        stopTask?.cancel()
        player?.stop()
        player = nil
        playing = nil
    }
}

struct SpeakerNamingView: View {
    let dir: URL
    let speakers: [MeetingSpeaker]
    let segments: [SpeakerSegment]
    let quotes: [String: [String]]
    let knownNames: [String]
    let close: (Bool) -> Void

    @State private var names: [String: String] = [:]
    @StateObject private var player = ClipPlayer()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Who was in this meeting?").font(.title2.bold())
            Text("Name each voice once. MeetRec remembers it and labels that person automatically next time. Voices stay on this Mac.")
                .font(.callout).foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(speakers, id: \.id) { s in row(s) }
                }
                .padding(.vertical, 4)
            }

            HStack {
                Spacer()
                Button("Skip") { player.stop(); close(false) }
                Button("Save names") {
                    player.stop()
                    try? applySpeakerNames(names, in: dir)
                    close(true)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 360)
        .onAppear {
            for s in speakers where s.known { names[s.id] = s.label }
        }
    }

    private func row(_ s: MeetingSpeaker) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                let clip = bestClip(for: s.id)
                player.toggle(id: s.id, file: dir.appendingPathComponent("others.m4a"), start: clip.start, duration: clip.length)
            } label: {
                Image(systemName: player.playing == s.id ? "stop.circle.fill" : "play.circle.fill").font(.system(size: 26))
            }
            .buttonStyle(.plain)
            .help("Play a clip of this voice")

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField(s.known ? s.label : "\(s.label) — type a name", text: binding(s.id))
                        .textFieldStyle(.roundedBorder)
                    if !knownNames.isEmpty {
                        Menu {
                            ForEach(knownNames, id: \.self) { n in Button(n) { names[s.id] = n } }
                        } label: { Image(systemName: "person.crop.circle") }
                        .menuStyle(.borderlessButton)
                        .frame(width: 36)
                        .help("Pick someone MeetRec already knows")
                    }
                }
                Text("\(Int(s.seconds))s of speech" + (s.known ? " · recognized" : " · new voice"))
                    .font(.caption).foregroundStyle(s.known ? .green : .orange)
                ForEach(quotes[s.id] ?? [], id: \.self) { q in
                    Text("“\(q)”").font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
            }
        }
    }

    private func binding(_ id: String) -> Binding<String> {
        Binding(get: { names[id] ?? "" }, set: { names[id] = $0 })
    }

    /// Longest stretch this voice spoke, capped at 8 seconds.
    private func bestClip(for id: String) -> (start: Double, length: Double) {
        let longest = segments.filter { $0.speaker == id }.max { ($0.end - $0.start) < ($1.end - $1.start) }
        guard let l = longest else { return (0, 5) }
        return (l.start, min(8, l.end - l.start))
    }
}
