import Foundation
import WhisperKit

/// WhisperKit reports download progress far more often than the UI polls, and each
/// report costs an actor hop. Collapse it to whole percentage points.
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1
    func shouldReport(_ fraction: Double) -> Bool {
        let step = Int((fraction * 100).rounded(.down))
        lock.lock(); defer { lock.unlock() }
        guard step != last else { return false }
        last = step
        return true
    }
}

/// WhisperKit. Slower and needs a model download, but covers ~99 languages —
/// including the Indic languages Apple's SpeechAnalyzer has no assets for — and
/// can both auto-detect the spoken language and translate it into English.
enum WhisperTranscribe {
    /// Only multilingual variants are offered: the `.en` builds cannot do
    /// Hindi or Malayalam, which is the reason this engine exists.
    static let variants: [[String: String]] = [
        ["id": "openai_whisper-base", "name": "Base — fastest, least accurate", "size": "~145 MB"],
        ["id": "openai_whisper-small", "name": "Small — balanced", "size": "~485 MB"],
        ["id": "openai_whisper-large-v3_turbo", "name": "Large v3 Turbo — most accurate", "size": "~1.6 GB"],
    ]
    static let defaultVariant = "openai_whisper-small"

    static func isKnownVariant(_ variant: String) -> Bool {
        variants.contains { $0["id"] == variant }
    }

    /// Whisper maps several aliases onto one code ("mandarin" and "chinese" both give
    /// "zh"), so collapse by code and prefer the system's own name for the language.
    static func languages() -> [[String: String]] {
        var byCode: [String: String] = [:]
        for (name, code) in Constants.languages {
            byCode[code] = Locale.current.localizedString(forLanguageCode: code)
                ?? name.prefix(1).uppercased() + name.dropFirst()
        }
        return byCode
            .map { ["id": $0.key, "name": $0.value] }
            .sorted { $0["name"]! < $1["name"]! }
    }

    static func isSupportedLanguage(_ code: String) -> Bool {
        code == Transcribe.autoDetect || Constants.languages.values.contains(code)
    }

    struct Outcome {
        var segments: [TranscriptSegment]
        var language: String
    }

    private struct ReadyModel: Codable {
        let formatVersion: Int
        let variant: String
    }

    private static let controlTokenPattern = try! NSRegularExpression(pattern: #"<\|[^|>]+\|>"#)

    private static func load(variant: String, modelRoot: URL, prewarm: Bool) async throws -> WhisperKit {
        guard let folder = modelFolder(for: variant, in: modelRoot), modelIsReady(variant, folder: folder) else {
            throw MeetMeError("The Whisper model \(variant) has not been downloaded yet. Download it in Settings before processing recordings.")
        }
        return try await WhisperKit(
            model: variant,
            downloadBase: modelRoot,
            modelFolder: folder.path,
            tokenizerFolder: modelRoot,
            verbose: false,
            prewarm: prewarm,
            load: true,
            download: false
        )
    }

    /// `task: .translate` makes Whisper emit English for any source language, which is
    /// how recordings in languages Apple Intelligence cannot summarise still get a summary.
    /// Whisper decodes in fixed 30-second windows, so the number of completed windows
    /// says how far into the recording it has reached.
    static let windowSeconds = 30.0

    static func run(audio: URL, variant: String, language: String, translate: Bool, modelRoot: URL,
                    duration: Double = 0, progress: (@Sendable (Double) -> Void)? = nil) async throws -> Outcome {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: audio.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: audio.path])
        }
        let whisper = try await load(variant: variant, modelRoot: modelRoot, prewarm: true)
        // Two 90-second chunks bound file buffering while VAD preserves the original timeline.
        let input = AudioInputOptions(
            channelMode: .sumChannels(nil),
            audioLoadingMode: .incremental(chunkDurationSeconds: 90, maxBufferedChunks: 2)
        )
        let auto = language == Transcribe.autoDetect
        let options = DecodingOptions(
            task: translate ? .translate : .transcribe,
            language: auto ? nil : language,
            detectLanguage: auto
        )
        let throttle = ProgressThrottle()
        let callback: TranscriptionCallback = { update in
            guard duration > 0 else { return nil }
            let reached = Double(update.windowId) * windowSeconds
            let fraction = min(1, max(0, reached / duration))
            if throttle.shouldReport(fraction) { progress?(fraction) }
            return nil
        }
        let results: [TranscriptionResult]
        do {
            results = try await whisper.transcribe(audioPath: audio.path, audioInputOptions: input, decodeOptions: options, callback: callback)
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
        guard !segments.isEmpty else { throw MeetMeError("Whisper completed without usable speech segments.") }
        let detected = results.first?.language ?? (auto ? "" : language)
        return Outcome(segments: segments, language: detected.isEmpty ? language : detected)
    }

    static func detect(audio: URL, variant: String, modelRoot: URL) async throws -> String {
        let whisper = try await load(variant: variant, modelRoot: modelRoot, prewarm: false)
        defer { Task { await whisper.unloadModels() } }
        return try await whisper.detectLanguage(audioPath: audio.path).language
    }

    static func download(variant: String, modelRoot: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try Task.checkCancellation()
        guard isKnownVariant(variant) else { throw MeetMeError("Unknown Whisper model \(variant)") }
        try FileManager.default.createDirectory(at: modelRoot, withIntermediateDirectories: true)
        let throttle = ProgressThrottle()
        let folder = try await WhisperKit.download(variant: variant, downloadBase: modelRoot) { value in
            let fraction = value.fractionCompleted
            if throttle.shouldReport(fraction) { progress?(fraction) }
        }
        // Fetch and persist the tokenizer now, so later inference remains offline.
        let whisper = try await WhisperKit(
            model: variant,
            downloadBase: modelRoot,
            modelFolder: folder.path,
            tokenizerFolder: modelRoot,
            verbose: false,
            prewarm: false,
            load: true,
            download: false
        )
        await whisper.unloadModels()
        try writeReadyMarker(for: variant, to: folder)
        try Task.checkCancellation()
    }

    static func isReady(variant: String, modelRoot: URL) -> Bool {
        guard let folder = modelFolder(for: variant, in: modelRoot) else { return false }
        return modelIsReady(variant, folder: folder)
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
