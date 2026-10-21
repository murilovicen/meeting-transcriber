import FluidAudio
import Foundation

let voicesURL = URL(fileURLWithPath: NSHomeDirectory() + "/.meetrec/voices.json")

/// A voice cluster found in one meeting's "others" track.
struct MeetingSpeaker: Codable {
    var id: String            // "S1", "S2"… stable within the meeting
    var label: String         // real name, or "Speaker N" until someone names it
    var known: Bool           // label came from the voice library or the user
    var distance: Float?      // distance to the matched voice, for tuning
    var seconds: Double       // how long they talked
    var embedding: [Float]
}

struct SpeakerSegment: Codable {
    var start: Double
    var end: Double
    var speaker: String
}

struct MeetingSpeakers: Codable {
    var speakers: [MeetingSpeaker]
    var segments: [SpeakerSegment]

    static func load(_ dir: URL) -> MeetingSpeakers? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("speakers.json")) else { return nil }
        return try? JSONDecoder().decode(MeetingSpeakers.self, from: data)
    }

    func save(_ dir: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: dir.appendingPathComponent("speakers.json"))
    }
}

func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return .infinity }
    var dot: Float = 0, na: Float = 0, nb: Float = 0
    for i in 0..<a.count {
        dot += a[i] * b[i]
        na += a[i] * a[i]
        nb += b[i] * b[i]
    }
    guard na > 0, nb > 0 else { return .infinity }
    return 1 - dot / (na.squareRoot() * nb.squareRoot())
}

/// Voiceprints of people you've named, kept only on this Mac.
struct VoiceLibrary: Codable {
    struct Person: Codable {
        var name: String
        var embeddings: [[Float]]
    }
    var people: [Person] = []

    /// Voices closer than this are treated as the same person.
    static let matchThreshold: Float = 0.5

    static func load() -> VoiceLibrary {
        guard let data = try? Data(contentsOf: voicesURL),
              let lib = try? JSONDecoder().decode(VoiceLibrary.self, from: data) else { return VoiceLibrary() }
        return lib
    }

    func save() throws {
        try FileManager.default.createDirectory(at: voicesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: voicesURL, options: [.atomic])
    }

    func match(_ embedding: [Float]) -> (name: String, distance: Float)? {
        var best: (String, Float)?
        for p in people {
            let d = p.embeddings.map { cosineDistance($0, embedding) }.min() ?? .infinity
            if d < (best?.1 ?? .infinity) { best = (p.name, d) }
        }
        guard let best, best.1 < Self.matchThreshold else { return nil }
        return best
    }

    /// Remembers a voice. Keeps the most recent 10 samples per person.
    mutating func add(name: String, embedding: [Float]) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !embedding.isEmpty else { return }
        if let i = people.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            people[i].embeddings.append(embedding)
            if people[i].embeddings.count > 10 { people[i].embeddings.removeFirst() }
        } else {
            people.append(Person(name: name, embeddings: [embedding]))
        }
    }

    var names: [String] { people.map(\.name).sorted() }
}

/// Splits the "others" track by voice and labels each voice from the library.
actor SpeakerIdentifier {
    static let shared = SpeakerIdentifier()
    private var manager: OfflineDiarizerManager?

    func prepare() async throws {
        if manager != nil { return }
        let m = OfflineDiarizerManager(config: .default)
        try await m.prepareModels()
        manager = m
    }

    func identify(_ dir: URL) async throws -> MeetingSpeakers {
        try await prepare()
        let audio = dir.appendingPathComponent("others.m4a")
        let samples = try AudioConverter().resampleAudioFile(audio)
        let result = try await manager!.process(audio: samples)

        // Order speakers by first appearance so "Speaker 1" is whoever talked first.
        var order: [String] = []
        var talk: [String: Double] = [:]
        for s in result.segments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) {
            if !order.contains(s.speakerId) { order.append(s.speakerId) }
            talk[s.speakerId, default: 0] += Double(s.durationSeconds)
        }
        let centroids = result.speakerDatabase ?? [:]
        let library = VoiceLibrary.load()

        var ids: [String: String] = [:]
        var speakers: [MeetingSpeaker] = []
        var unknown = 0
        for raw in order {
            let id = "S\(speakers.count + 1)"
            ids[raw] = id
            let embedding = centroids[raw] ?? averageEmbedding(result.segments.filter { $0.speakerId == raw })
            if let m = library.match(embedding) {
                speakers.append(MeetingSpeaker(id: id, label: m.name, known: true, distance: m.distance,
                                               seconds: talk[raw] ?? 0, embedding: embedding))
            } else {
                unknown += 1
                speakers.append(MeetingSpeaker(id: id, label: "Speaker \(unknown)", known: false, distance: nil,
                                               seconds: talk[raw] ?? 0, embedding: embedding))
            }
        }
        let segments = result.segments.map {
            SpeakerSegment(start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds), speaker: ids[$0.speakerId] ?? "S?")
        }
        let found = MeetingSpeakers(speakers: speakers, segments: segments)
        try found.save(dir)
        log("  voices: " + speakers.map { "\($0.label)\($0.known ? " ✓" : "") \(Int($0.seconds))s" }.joined(separator: ", "))
        return found
    }

    private func averageEmbedding(_ segs: [TimedSpeakerSegment]) -> [Float] {
        guard let n = segs.first?.embedding.count, n > 0 else { return [] }
        var sum = [Float](repeating: 0, count: n)
        for s in segs where s.embedding.count == n {
            for i in 0..<n { sum[i] += s.embedding[i] }
        }
        return sum.map { $0 / Float(segs.count) }
    }
}

/// Applies names chosen by the user: updates the meeting, teaches the library, and rebuilds the transcript.
func applySpeakerNames(_ names: [String: String], in dir: URL) throws {
    guard var meeting = MeetingSpeakers.load(dir) else { return }
    var library = VoiceLibrary.load()
    for i in meeting.speakers.indices {
        guard let name = names[meeting.speakers[i].id]?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { continue }
        meeting.speakers[i].label = name
        meeting.speakers[i].known = true
        library.add(name: name, embedding: meeting.speakers[i].embedding)
    }
    try meeting.save(dir)
    try library.save()
    rebuildTranscript(dir)
}

func mergeScript() -> URL? {
    transcribeScript()?.deletingLastPathComponent().appendingPathComponent("merge.py")
}

func rebuildTranscript(_ dir: URL) {
    guard let merge = mergeScript() else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    p.arguments = [merge.path, dir.path]
    try? p.run()
    p.waitUntilExit()
}
