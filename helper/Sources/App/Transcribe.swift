import Foundation

struct TranscriptSegment: Codable, Sendable {
    var start: Double
    var end: Double
    var text: String
    /// Who the meeting page showed speaking here; absent when nothing was logged.
    var speaker: String? = nil

    /// The text as written to exports and shown to the summariser.
    var attributedText: String { speaker.map { "\($0): \(text)" } ?? text }
}

/// Fronts the two transcription engines. Apple's is the default because it needs no
/// download; Whisper covers the languages Apple has no assets for and can auto-detect.
enum Transcribe {
    static let autoDetect = "auto"

    enum Engine: String, Sendable {
        case apple
        case whisper

        static func parse(_ value: String) -> Engine { Engine(rawValue: value) ?? .apple }
    }

    struct Outcome: Sendable {
        var segments: [TranscriptSegment]
        /// The language actually used, which for auto-detect is what Whisper heard.
        var language: String
    }

    static func engines() async -> [[String: Any]] {
        [
            ["id": Engine.apple.rawValue,
             "name": "Apple (on-device)",
             "detail": "Fast, no download. Limited to Apple's built-in languages.",
             "supportsAutoDetect": false,
             "languages": await AppleTranscribe.languages()],
            ["id": Engine.whisper.rawValue,
             "name": "Whisper (on-device)",
             "detail": "Covers ~99 languages including Hindi and Malayalam. Needs a one-time model download.",
             "supportsAutoDetect": true,
             "languages": WhisperTranscribe.languages()],
        ]
    }

    static func validate(engine: Engine, language: String, variant: String) async throws {
        switch engine {
        case .apple:
            guard language != autoDetect else {
                throw MeetMeError("Apple's engine cannot detect the language automatically. Choose a language, or switch to Whisper.")
            }
            _ = try await AppleTranscribe.locale(for: language)
        case .whisper:
            guard WhisperTranscribe.isKnownVariant(variant) else { throw MeetMeError("Unknown Whisper model \(variant)") }
            guard WhisperTranscribe.isSupportedLanguage(language) else {
                throw MeetMeError("Whisper does not support the language \(language)")
            }
        }
    }

    static func run(audio: URL, engine: Engine, language: String, variant: String, modelRoot: URL,
                    duration: Double = 0, progress: (@Sendable (Double) -> Void)? = nil) async throws -> Outcome {
        switch engine {
        case .apple:
            let segments = try await AppleTranscribe.run(audio: audio, model: language, duration: duration, progress: progress)
            return Outcome(segments: segments, language: language)
        case .whisper:
            let outcome = try await WhisperTranscribe.run(audio: audio, variant: variant, language: language, translate: false,
                                                          modelRoot: modelRoot, duration: duration, progress: progress)
            return Outcome(segments: outcome.segments, language: outcome.language)
        }
    }

    /// English rendering of the same audio, used when the spoken language is one
    /// Apple Intelligence cannot summarise. Only Whisper can do this.
    static func translateToEnglish(audio: URL, engine: Engine, language: String, variant: String, modelRoot: URL,
                                   duration: Double = 0, progress: (@Sendable (Double) -> Void)? = nil) async throws -> [TranscriptSegment] {
        guard engine == .whisper else {
            throw MeetMeError("Translation requires the Whisper engine.")
        }
        return try await WhisperTranscribe.run(audio: audio, variant: variant, language: language, translate: true,
                                               modelRoot: modelRoot, duration: duration, progress: progress).segments
    }

    static func download(engine: Engine, language: String, variant: String, modelRoot: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        switch engine {
        case .apple: try await AppleTranscribe.download(model: language)
        case .whisper: try await WhisperTranscribe.download(variant: variant, modelRoot: modelRoot, progress: progress)
        }
    }

    static func isReady(engine: Engine, language: String, variant: String, modelRoot: URL) async -> Bool {
        switch engine {
        case .apple:
            guard language != autoDetect else { return false }
            return await AppleTranscribe.isReady(model: language)
        case .whisper:
            return WhisperTranscribe.isReady(variant: variant, modelRoot: modelRoot)
        }
    }
}
