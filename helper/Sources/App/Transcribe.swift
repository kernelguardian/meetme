import Foundation
import Speech
import AVFoundation

struct TranscriptSegment: Codable, Sendable {
    var start: Double
    var end: Double
    var text: String
}

enum Transcribe {
    static func languages() async -> [[String:String]] {
        await SpeechTranscriber.supportedLocales.map {
            ["id": $0.identifier.replacingOccurrences(of: "_", with: "-"), "name": Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier]
        }.sorted { $0["name"]! < $1["name"]! }
    }

    static func locale(for model: String) async throws -> Locale {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: model)) else {
            throw MeetMeError("Apple native transcription is unavailable for this language or device. Choose a supported language in Settings.")
        }
        return locale
    }

    static func download(model: String, modelRoot: URL) async throws {
        let locale = try await locale(for: model)
        try Task.checkCancellation()
        try await AssetInventory.reserve(locale: locale)
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()
    }

    static func isReady(model: String, modelRoot: URL) async -> Bool {
        guard let locale = try? await locale(for: model) else { return false }
        return await AssetInventory.status(forModules: [SpeechTranscriber(locale: locale, preset: .transcription)]) == .installed
    }

    static func run(audio: URL, model: String, modelRoot: URL) async throws -> [TranscriptSegment] {
        try await download(model: model, modelRoot: modelRoot)
        let locale = try await locale(for: model)
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task<[TranscriptSegment], Error> {
            var segments: [TranscriptSegment] = []
            for try await result in transcriber.results {
                try Task.checkCancellation()
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                let start = result.range.start.seconds
                let end = CMTimeRangeGetEnd(result.range).seconds
                if !text.isEmpty, start.isFinite, end.isFinite, end >= start {
                    segments.append(TranscriptSegment(start: max(0, start), end: end, text: text))
                }
            }
            return segments
        }
        return try await withTaskCancellationHandler {
            do {
                let file = try AVAudioFile(forReading: audio)
                if let end = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: end)
                } else {
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                }
                let segments = try await collector.value
                try Task.checkCancellation()
                guard !segments.isEmpty else { throw MeetMeError("Apple transcription found no speech in this recording.") }
                return segments
            } catch {
                await analyzer.cancelAndFinishNow()
                collector.cancel()
                _ = try? await collector.value
                throw error
            }
        } onCancel: {
            collector.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }
}
