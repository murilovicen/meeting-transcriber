import AVFoundation

func hostNow() -> Double { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }

/// Writes one audio track to an .m4a, padding gaps with silence so both tracks share a timeline.
final class TrackWriter {
    private let url: URL
    private let start: Double
    private var file: AVAudioFile?
    private var written: AVAudioFramePosition = 0

    init(url: URL, start: Double) {
        self.url = url
        self.start = start
    }

    func write(_ buffer: AVAudioPCMBuffer, hostSeconds: Double) {
        let format = buffer.format
        if file == nil {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
            ]
            do {
                file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            } catch {
                log("could not open \(url.lastPathComponent): \(error)")
                return
            }
        }
        guard let file else { return }

        // Clocks that look nonsensical fall back to "now" rather than wrecking alignment.
        let t = abs(hostSeconds - hostNow()) > 5 ? hostNow() : hostSeconds
        var gap = AVAudioFramePosition((t - start) * format.sampleRate) - written
        if gap > AVAudioFramePosition(format.sampleRate / 10) {
            while gap > 0 {
                let n = AVAudioFrameCount(min(gap, AVAudioFramePosition(format.sampleRate)))
                guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n) else { break }
                silence.frameLength = n
                for b in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
                    if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) }
                }
                try? file.write(from: silence)
                written += AVAudioFramePosition(n)
                gap -= AVAudioFramePosition(n)
            }
        }
        do {
            try file.write(from: buffer)
            written += AVAudioFramePosition(buffer.frameLength)
        } catch {
            log("write failed for \(url.lastPathComponent): \(error)")
        }
    }

    func close() { file = nil }
}

/// Records the mic ("me") and everything the Mac plays ("others") into two aligned tracks.
final class Recorder {
    let dir: URL
    let startedAt = Date()
    private let engine = AVAudioEngine()
    private let tap = SystemAudioTap()
    private let mic: TrackWriter
    private let system: TrackWriter
    /// Extra consumers of each track (live captions). Set before start().
    var onMic: ((AVAudioPCMBuffer) -> Void)?
    var onSystem: ((AVAudioPCMBuffer) -> Void)?

    init(dir: URL) {
        self.dir = dir
        let start = hostNow()
        mic = TrackWriter(url: dir.appendingPathComponent("me.m4a"), start: start)
        system = TrackWriter(url: dir.appendingPathComponent("others.m4a"), start: start)
    }

    func start() throws {
        let input = engine.inputNode
        let onMic = self.onMic, onSystem = self.onSystem
        input.installTap(onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0)) { [mic] buf, time in
            mic.write(buf, hostSeconds: time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : hostNow())
            onMic?(buf)
        }
        try engine.start()
        do {
            try tap.start { [system] buf, t in
                system.write(buf, hostSeconds: t)
                onSystem?(buf)
            }
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            throw error
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        tap.stop()
        system.close()
        mic.close()
    }
}
