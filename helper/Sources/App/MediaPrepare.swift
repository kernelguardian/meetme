import Foundation

enum MediaPrepare {
    private enum MediaError: LocalizedError {
        case ffmpegUnavailable
        case missingInput(URL)
        case commandFailed(String)
        case invalidMedia(String)

        var errorDescription: String? {
            switch self {
            case .ffmpegUnavailable:
                return "FFmpeg and FFprobe are required to prepare recordings. Install the bundled tools and restart MeetMe."
            case let .missingInput(url):
                return "The media file is missing: \(url.lastPathComponent)."
            case let .commandFailed(message):
                return "FFmpeg could not prepare the recording: \(message)"
            case let .invalidMedia(message):
                return "The prepared media could not be validated: \(message)"
            }
        }
    }

    static func available() -> Bool {
        executable(named: "ffmpeg") != nil && executable(named: "ffprobe") != nil
    }

    /// Remuxes the assembled WebM without re-encoding, validates it, then atomically promotes it.
    static func finalize(input: URL, output: URL) throws -> Double {
        guard FileManager.default.fileExists(atPath: input.path) else { throw MediaError.missingInput(input) }
        guard let ffmpeg = executable(named: "ffmpeg") else { throw MediaError.ffmpegUnavailable }

        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = output.deletingLastPathComponent()
            .appendingPathComponent(".\(output.lastPathComponent).\(UUID().uuidString).tmp.webm")
        defer { try? FileManager.default.removeItem(at: temporary) }

        try run(ffmpeg, [
            "-hide_banner", "-loglevel", "error", "-y", "-fflags", "+genpts",
            "-i", input.path, "-map", "0", "-c", "copy", "-map_metadata", "0", temporary.path
        ])
        let duration = try validatedDuration(of: temporary, requireAudio: true)
        try promote(temporary, to: output)
        return duration
    }

    /// Extracts the meeting mix as 16 kHz mono PCM; WhisperKit is never given WebM/Opus directly.
    static func audio(video: URL, output: URL) throws {
        guard FileManager.default.fileExists(atPath: video.path) else { throw MediaError.missingInput(video) }
        guard let ffmpeg = executable(named: "ffmpeg") else { throw MediaError.ffmpegUnavailable }

        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = output.deletingLastPathComponent()
            .appendingPathComponent(".\(output.lastPathComponent).\(UUID().uuidString).tmp.wav")
        defer { try? FileManager.default.removeItem(at: temporary) }

        try run(ffmpeg, [
            "-hide_banner", "-loglevel", "error", "-y", "-i", video.path,
            "-map", "0:a:0", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", temporary.path
        ])
        let videoDuration = try validatedDuration(of: video, requireAudio: true)
        let audioDuration = try validateWAV(temporary)
        let allowedDrift = max(0.5, videoDuration * 0.01)
        guard abs(videoDuration - audioDuration) <= allowedDrift else {
            throw MediaError.invalidMedia("Extracted audio duration differs from the recording timeline.")
        }
        try promote(temporary, to: output)
    }

    private static func executable(named name: String) -> URL? {
        let environmentName = name == "ffmpeg" ? "MEETME_FFMPEG" : "MEETME_FFPROBE"
        if let path = ProcessInfo.processInfo.environment[environmentName], isExecutable(path) {
            return URL(fileURLWithPath: path)
        }

        let helperDirectory = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .resolvingSymlinksInPath().deletingLastPathComponent()
        let candidates = [
            helperDirectory.appendingPathComponent(name).path,
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        return candidates.first(where: isExecutable).map { URL(fileURLWithPath: $0) }
    }

    private static func isExecutable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    private static func run(_ executable: URL, _ arguments: [String]) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let message = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown error"
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw MediaError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func probe(_ media: URL) throws -> String {
        guard let ffprobe = executable(named: "ffprobe") else { throw MediaError.ffmpegUnavailable }
        let process = Process()
        let output = Pipe()
        process.executableURL = ffprobe
        process.arguments = ["-v", "error", "-show_entries", "format=format_name,duration:stream=codec_type,codec_name,sample_rate,channels", "-of", "json", media.path]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw MediaError.invalidMedia(text) }
        return text
    }

    private static func validatedDuration(of media: URL, requireAudio: Bool) throws -> Double {
        let data = try probe(media).data(using: .utf8) ?? Data()
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let format = object["format"] as? [String: Any],
              let durationText = format["duration"] as? String,
              let duration = Double(durationText), duration.isFinite, duration > 0 else {
            throw MediaError.invalidMedia("FFprobe did not report a positive duration.")
        }
        if requireAudio {
            let streams = object["streams"] as? [[String: Any]] ?? []
            guard streams.contains(where: { ($0["codec_type"] as? String) == "audio" }) else {
                throw MediaError.invalidMedia("The finalized recording has no audio stream.")
            }
        }
        return duration
    }

    private static func validateWAV(_ media: URL) throws -> Double {
        let duration = try validatedDuration(of: media, requireAudio: true)
        let data = try probe(media).data(using: .utf8) ?? Data()
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let formats = ((object?["format"] as? [String: Any])?["format_name"] as? String ?? "").split(separator: ",")
        let stream = (object?["streams"] as? [[String: Any]] ?? []).first { ($0["codec_type"] as? String) == "audio" }
        guard formats.contains("wav"), stream?["codec_name"] as? String == "pcm_s16le", stream?["sample_rate"] as? String == "16000", stream?["channels"] as? Int == 1 else {
            throw MediaError.invalidMedia("Extracted audio is not mono 16 kHz WAV.")
        }
        return duration
    }

    private static func promote(_ temporary: URL, to destination: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try manager.moveItem(at: temporary, to: destination)
        }
    }
}
