import Foundation
import WhisperKit

struct TranscriptSegment: Codable, Sendable {
    var start: Double
    var end: Double
    var text: String
}

enum Transcribe {
    private struct ReadyModel: Codable {
        let formatVersion: Int
        let variant: String
    }

    private enum TranscriptionError: LocalizedError {
        case modelNotReady(String)
        case noSpeech

        var errorDescription: String? {
            switch self {
            case let .modelNotReady(model):
                return "The Whisper model \(model) has not been downloaded yet. Download it before processing recordings."
            case .noSpeech:
                return "WhisperKit completed without usable speech segments."
            }
        }
    }

    private static let controlTokenPattern = try! NSRegularExpression(pattern: #"<\|[^|>]+\|>"#)

    static func run(audio: URL, model: String, modelRoot: URL) async throws -> [TranscriptSegment] {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: audio.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: audio.path])
        }
        guard let folder = modelFolder(for: model, in: modelRoot), modelIsReady(model, folder: folder) else {
            throw TranscriptionError.modelNotReady(model)
        }

        let whisper = try await WhisperKit(
            model: model,
            downloadBase: modelRoot,
            modelFolder: folder.path,
            tokenizerFolder: modelRoot,
            verbose: false,
            prewarm: true,
            load: true,
            download: false
        )
        // Two 90-second chunks bound file buffering while VAD preserves the original timeline.
        let input = AudioInputOptions(
            channelMode: .sumChannels(nil),
            audioLoadingMode: .incremental(chunkDurationSeconds: 90, maxBufferedChunks: 2)
        )
        let results: [TranscriptionResult]
        do {
            results = try await whisper.transcribe(audioPath: audio.path, audioInputOptions: input)
            try Task.checkCancellation()
            await whisper.unloadModels()
        } catch {
            await whisper.unloadModels()
            throw error
        }

        let segments = results.flatMap { result in
            result.segments.compactMap { segment -> TranscriptSegment? in
                let text = clean(segment.text)
                guard !text.isEmpty, segment.end >= segment.start else { return nil }
                return TranscriptSegment(start: Double(segment.start), end: Double(segment.end), text: text)
            }
        }
        guard !segments.isEmpty else { throw TranscriptionError.noSpeech }
        return segments
    }

    static func download(model: String, modelRoot: URL) async throws {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: modelRoot, withIntermediateDirectories: true)
        let folder = try await WhisperKit.download(variant: model, downloadBase: modelRoot)
        // Fetch and persist the tokenizer now, so later inference remains offline.
        let whisper = try await WhisperKit(
            model: model,
            downloadBase: modelRoot,
            modelFolder: folder.path,
            tokenizerFolder: modelRoot,
            verbose: false,
            prewarm: false,
            load: true,
            download: false
        )
        await whisper.unloadModels()
        try writeReadyMarker(for: model, to: folder)
        try Task.checkCancellation()
    }

    static func isReady(model: String, modelRoot: URL) -> Bool {
        guard let folder = modelFolder(for: model, in: modelRoot) else { return false }
        return modelIsReady(model, folder: folder)
    }

    private static func modelFolder(for model: String, in root: URL) -> URL? {
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        let normalized = normalizedVariant(model)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        if isModelFolder(root), normalizedVariant(root.lastPathComponent) == normalized {
            return root
        }
        for case let candidate as URL in enumerator {
            guard candidate.lastPathComponent == "AudioEncoder.mlmodelc" else { continue }
            let folder = candidate.deletingLastPathComponent()
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("TextDecoder.mlmodelc").path) else { continue }
            if normalizedVariant(folder.lastPathComponent) == normalized {
                return folder
            }
        }
        return nil
    }

    private static func isModelFolder(_ url: URL) -> Bool {
        let manager = FileManager.default
        return manager.fileExists(atPath: url.appendingPathComponent("AudioEncoder.mlmodelc").path)
            && manager.fileExists(atPath: url.appendingPathComponent("TextDecoder.mlmodelc").path)
    }

    /// A successful WhisperKit load creates this marker only after it has loaded the
    /// tokenizer selected from the model's decoded vocabulary. This prevents a tokenizer
    /// belonging to another Whisper variant from making this model appear ready.
    private static func modelIsReady(_ model: String, folder: URL) -> Bool {
        guard isModelFolder(folder),
              let data = try? Data(contentsOf: readyMarkerURL(in: folder)),
              let marker = try? JSONDecoder().decode(ReadyModel.self, from: data) else { return false }
        return marker.formatVersion == 1 && marker.variant == normalizedVariant(model)
    }

    private static func writeReadyMarker(for model: String, to folder: URL) throws {
        let marker = ReadyModel(formatVersion: 1, variant: normalizedVariant(model))
        let destination = readyMarkerURL(in: folder)
        let temporary = folder.appendingPathComponent(".meetme-ready-\(UUID().uuidString).tmp")
        try JSONEncoder().encode(marker).write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }

    private static func readyMarkerURL(in folder: URL) -> URL {
        folder.appendingPathComponent(".meetme-whisper-ready.json")
    }

    private static func normalizedVariant(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: "_", with: "-")
    }

    private static func clean(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return controlTokenPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
