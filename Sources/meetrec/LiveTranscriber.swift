import AVFoundation
import Speech

struct CaptionLine: Identifiable {
    let id = UUID()
    let speaker: String
    var text: String
    var updated: Date
}

/// What the captions window shows: finished lines plus the in-progress phrase of each speaker.
@MainActor
final class Captions: ObservableObject {
    @Published var lines: [CaptionLine] = []
    @Published var partial: [String: String] = [:]
    @Published var status = ""

    private var startedAt = Date()
    private var firstWords: Set<String> = []
    private var updates: [String: Int] = [:]

    var stats: String { updates.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ") }

    func reset() {
        lines = []
        partial = [:]
        startedAt = Date()
        firstWords = []
        updates = [:]
    }

    private func words(_ s: String) -> Set<String> {
        Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 })
    }

    /// Without headphones the mic hears the call too; treat "Me" text that mostly repeats recent "Others" text as echo.
    private func isEcho(_ text: String) -> Bool {
        let mine = words(text)
        guard mine.count >= 2 else { return false }
        var theirs = words(partial["Others"] ?? "")
        for l in lines.suffix(4) where l.speaker == "Others" && Date().timeIntervalSince(l.updated) < 15 {
            theirs.formUnion(words(l.text))
        }
        return Double(mine.intersection(theirs).count) / Double(mine.count) > 0.6
    }

    func update(speaker: String, text: String, isFinal: Bool) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        updates[speaker, default: 0] += 1
        if !text.isEmpty && !firstWords.contains(speaker) {
            firstWords.insert(speaker)
            log("  live captions: first \(isFinal ? "final" : "partial") words from \(speaker) \(String(format: "%.1f", Date().timeIntervalSince(startedAt)))s into the call")
        }
        if speaker == "Me" && isEcho(text) {
            partial[speaker] = nil
            return
        }
        guard isFinal else {
            partial[speaker] = text
            return
        }
        partial[speaker] = nil
        guard !text.isEmpty else { return }
        if var last = lines.last, last.speaker == speaker, Date().timeIntervalSince(last.updated) < 6 {
            last.text += " " + text
            last.updated = Date()
            lines[lines.count - 1] = last
        } else {
            lines.append(CaptionLine(speaker: speaker, text: text, updated: Date()))
            if lines.count > 200 { lines.removeFirst(lines.count - 200) }
        }
    }
}

/// Makes sure the on-device model for `locale` is installed, so it never downloads mid-call.
func prepareLiveModel(_ locale: Locale) async {
    let t = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
    do {
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
            log("downloading \(locale.identifier) live-captions model…")
            try await install.downloadAndInstall()
            log("  \(locale.identifier) model ready")
        }
    } catch {
        log("could not prepare \(locale.identifier) live-captions model: \(error.localizedDescription)")
    }
}

/// Streams one audio track into Apple's on-device SpeechAnalyzer (macOS 26).
final class LiveTranscriber {
    let speaker: String
    private let lock = NSLock()
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var target: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var analyzer: SpeechAnalyzer?
    private var results: Task<Void, Never>?

    init(speaker: String) { self.speaker = speaker }

    func start(locale: Locale, captions: Captions) async throws {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            await MainActor.run { captions.status = "Downloading \(locale.identifier) speech model…" }
            try await install.downloadAndInstall()
            await MainActor.run { captions.status = "" }
        }
        let t0 = Date()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        // Accept audio right away; the stream buffers it while the model loads, so nothing is lost.
        lock.withLock {
            self.analyzer = analyzer
            self.target = format
            self.input = continuation
        }

        let speaker = self.speaker
        results = Task {
            do {
                for try await r in transcriber.results {
                    let text = String(r.text.characters)
                    let final = r.isFinal
                    await MainActor.run { captions.update(speaker: speaker, text: text, isFinal: final) }
                }
            } catch {
                log("live captions (\(speaker)) stopped: \(error.localizedDescription)")
            }
        }
        try await analyzer.prepareToAnalyze(in: format)
        try await analyzer.start(inputSequence: stream)
        log("  live captions (\(speaker)) ready in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
    }

    /// Called from audio threads.
    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let input, let target else { return }
        if converter == nil || converter!.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, out.frameLength > 0 { input.yield(AnalyzerInput(buffer: out)) }
    }

    func stop() async {
        let (analyzer, input) = lock.withLock { () -> (SpeechAnalyzer?, AsyncStream<AnalyzerInput>.Continuation?) in
            defer {
                self.input = nil
                self.target = nil
            }
            return (self.analyzer, self.input)
        }
        input?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        results?.cancel()
    }
}
