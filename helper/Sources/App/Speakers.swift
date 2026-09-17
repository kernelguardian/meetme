import Foundation

/// Who the meeting page showed as speaking, on the recording's own timeline. The
/// extension's content script logs these while capturing; nothing here listens to audio.
struct SpeakerInterval: Codable, Sendable {
    var start: Double
    var end: Double
    var name: String
}

enum Speakers {
    static let fileName = "speakers.jsonl"
    private static let maximumPerRequest = 500
    private static let maximumFileBytes = 8 * 1024 * 1024

    /// The intervals come from a web page, so nothing about them is trusted.
    static func sanitize(_ raw: Any?) -> [SpeakerInterval] {
        guard let items = raw as? [[String: Any]] else { return [] }
        return items.prefix(maximumPerRequest).compactMap { item in
            guard let start = (item["start"] as? NSNumber)?.doubleValue, let end = (item["end"] as? NSNumber)?.doubleValue,
                  start.isFinite, end.isFinite, end > start, end < 86_400, let rawName = item["name"] as? String else { return nil }
            let name = String(rawName.components(separatedBy: .controlCharacters).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
            guard !name.isEmpty else { return nil }
            return SpeakerInterval(start: max(0, start), end: end, name: name)
        }
    }

    static func append(_ intervals: [SpeakerInterval], folder: URL) throws -> Int {
        guard !intervals.isEmpty else { return 0 }
        let url = folder.appendingPathComponent(fileName)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size < maximumFileBytes else { return 0 }
        let encoder = JSONEncoder()
        var payload = Data()
        for interval in intervals { payload.append(try encoder.encode(interval)); payload.append(0x0A) }
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: payload)
        return intervals.count
    }

    static func load(folder: URL) -> [SpeakerInterval] {
        guard let text = try? String(contentsOf: folder.appendingPathComponent(fileName), encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { try? decoder.decode(SpeakerInterval.self, from: Data($0.utf8)) }
            .sorted { $0.start < $1.start }
    }

    /// Each segment takes the name that was shown speaking for most of it. The page's
    /// indicator trails the audio a little, so the window is widened before matching,
    /// and a segment nobody clearly owns is left unlabelled rather than guessed.
    static func assign(_ segments: [TranscriptSegment], intervals: [SpeakerInterval]) -> [TranscriptSegment] {
        guard !intervals.isEmpty else { return segments }
        return segments.map { segment in
            let from = segment.start - 0.3, to = max(segment.end, segment.start + 0.5) + 0.5
            var overlap: [String: Double] = [:]
            for interval in intervals {
                if interval.start >= to { break }
                let shared = min(to, interval.end) - max(from, interval.start)
                if shared > 0 { overlap[interval.name, default: 0] += shared }
            }
            var labelled = segment
            if let best = overlap.max(by: { $0.value < $1.value }), best.value >= 0.4 {
                labelled.speaker = best.key
            } else {
                labelled.speaker = nil
            }
            return labelled
        }
    }
}
