import Foundation
import CryptoKit
import Darwin

struct MeetMeError: LocalizedError { let message: String; init(_ message: String) { self.message = message }; var errorDescription: String? { message } }
func isoNow() -> String { ISO8601DateFormatter().string(from: Date()) }
func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func durableWrite(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .atomic)
    let fd = Darwin.open(url.path, O_RDONLY)
    guard fd >= 0 else { throw MeetMeError("Cannot open saved file for synchronization") }
    defer { Darwin.close(fd) }
    guard Darwin.fsync(fd) == 0 else { throw MeetMeError("Cannot synchronize saved file") }
    let dir = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY)
    if dir >= 0 { _ = Darwin.fsync(dir); Darwin.close(dir) }
}
struct ChunkReceipt: Codable { var bytes: Int; var checksum: String }
struct Recording: Codable {
    var id: String
    var title: String
    var platform: String
    var createdAt: String
    var endedAt: String? = nil
    var duration: Double? = nil
    var status: String = "recording"
    var jobStatus: String = "none"
    var jobStage: String = "all"
    var error: String? = nil
    var micEnabled: Bool
    var participants: [String]? = nil
    var chunkCount: Int = 0
    var totalBytes: Int = 0
    var chunks: [String: ChunkReceipt] = [:]
    var model: String? = nil
    /// The language actually transcribed, which for auto-detect is what Whisper heard.
    var language: String? = nil
    var hasTranscript: Bool = false
    var hasSummary: Bool = false
    var hasTranslation: Bool = false
    /// Why a ready transcript has no summary, when that is expected rather than a failure.
    var summarySkipped: String? = nil
}
struct Configuration: Codable {
    var libraryPath: String? = nil
    var model: String = "en-US"
    var engine: String = "apple"
    var whisperVariant: String = WhisperTranscribe.defaultVariant
}
final class Library: @unchecked Sendable {
    let lock = NSRecursiveLock()
    let configDir: URL
    let modelRoot: URL
    private var config: Configuration
    private var locations: [String:URL] = [:]
    init(configDirectory: URL? = nil, initialLibrary: URL? = nil) throws {
        let env = ProcessInfo.processInfo.environment
        configDir = configDirectory ?? URL(fileURLWithPath: env["MEETME_CONFIG_DIR"] ?? NSHomeDirectory()+"/Library/Application Support/MeetMe", isDirectory: true)
        modelRoot = configDir.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: modelRoot, withIntermediateDirectories: true)
        config = (try? JSONDecoder().decode(Configuration.self, from: Data(contentsOf: configDir.appendingPathComponent("config.json")))) ?? Configuration()
        // Configs written before the engine setting stored a Whisper variant in `model`.
        if config.model.hasPrefix("openai_whisper-") {
            config.engine = Transcribe.Engine.whisper.rawValue
            config.whisperVariant = WhisperTranscribe.isKnownVariant(config.model) ? config.model : WhisperTranscribe.defaultVariant
            config.model = Transcribe.autoDetect
            try saveConfig()
        }
        if let path = initialLibrary?.path ?? env["MEETME_LIBRARY_DIR"] { config.libraryPath = path; try FileManager.default.createDirectory(atPath:path, withIntermediateDirectories:true) }
        try refresh(recover: true)
    }
    func locked<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }
    var libraryPath: String? { locked { config.libraryPath } }
    var model: String { locked { config.model } }
    var engine: Transcribe.Engine { locked { Transcribe.Engine.parse(config.engine) } }
    var whisperVariant: String { locked { config.whisperVariant } }
    func setModel(_ model: String) throws { try locked {
        guard !model.isEmpty, model.count <= 64 else { throw MeetMeError("Choose a supported transcription language") }
        config.model = model; try saveConfig()
    } }
    func setEngine(_ engine: Transcribe.Engine) throws { try locked {
        config.engine = engine.rawValue; try saveConfig()
    } }
    func setWhisperVariant(_ variant: String) throws { try locked {
        guard WhisperTranscribe.isKnownVariant(variant) else { throw MeetMeError("Unknown Whisper model \(variant)") }
        config.whisperVariant = variant; try saveConfig()
    } }
    func selectFolder(_ url: URL) throws { try locked {
        guard !all().contains(where: { $0.status == "recording" || $0.jobStatus == "running" }) else { throw MeetMeError("Stop recording and processing before changing the library") }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let selected = try validatedDirectory(url, beneath: nil)
        let probe = selected.appendingPathComponent(".meetme-"+UUID().uuidString)
        try durableWrite(Data(), to: probe); try FileManager.default.removeItem(at: probe)
        config.libraryPath = selected.path; try saveConfig(); try refresh(recover: true)
    } }
    private func saveConfig() throws { try durableWrite(JSONEncoder().encode(config), to: configDir.appendingPathComponent("config.json")) }
    private func refresh(recover: Bool) throws { try locked {
        locations = [:]
        guard let path = config.libraryPath else { return }
        guard FileManager.default.fileExists(atPath:path) else { return }
        let root = try libraryRoot()
        for folder in try FileManager.default.contentsOfDirectory(at:root, includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey], options:.skipsHiddenFiles) {
            guard let folder = try? validatedDirectory(folder, beneath: root),
                  var rec = try? decodeRecording(in:folder), UUID(uuidString:rec.id) != nil else { continue }
            locations[rec.id] = folder
            if recover {
                if rec.status == "recording" || rec.status == "finalizing" { rec.status = "incomplete"; rec.error = "Recording interrupted. Committed chunks can be recovered." }
                if rec.jobStatus == "running" { rec.jobStatus = "queued"; rec.error = "Processing was interrupted and will restart." }
                try save(rec)
            }
        }
    } }
    func folder(_ id: String) throws -> URL { try locked {
        guard UUID(uuidString:id) != nil, let url = locations[id] else { throw MeetMeError("Recording not found") }
        return try validatedDirectory(url, beneath: libraryRoot())
    } }
    func get(_ id: String) throws -> Recording { try locked {
        return try decodeRecording(in:folder(id))
    } }
    func save(_ rec: Recording) throws { try locked {
        let folder = try folder(rec.id), meta = folder.appendingPathComponent("meta.json")
        if FileManager.default.fileExists(atPath:meta.path) { _ = try regularFile(meta, beneath: folder, maximumBytes: 4 * 1024 * 1024) }
        try durableWrite(JSONEncoder().encode(rec), to:meta)
    } }
    func update(_ id: String, _ body: (inout Recording) -> Void) throws -> Recording { try locked { var rec = try get(id); body(&rec); try save(rec); return rec } }
    func all() -> [Recording] { locked { locations.keys.compactMap { try? get($0) }.sorted { $0.createdAt > $1.createdAt } } }
    func create(title: String, platform: String, mic: Bool, participants: [String] = []) throws -> Recording { try locked {
        guard config.libraryPath != nil else { throw MeetMeError("Choose an available library folder in Settings first") }
        let root = try libraryRoot()
        guard !all().contains(where: { $0.status == "recording" || $0.status == "finalizing" }) else { throw MeetMeError("A recording is already active") }
        try checkSpace(root, required: 512*1024*1024)
        let id = UUID().uuidString.lowercased()
        let safeTitle = String(title.prefix(100)).replacingOccurrences(of:"[^a-zA-Z0-9 _-]",with:"",options:.regularExpression)
        let folder = root.appendingPathComponent(isoNow().replacingOccurrences(of:":",with:"-")+"_"+safeTitle+"_"+id)
        try FileManager.default.createDirectory(at:folder.appendingPathComponent("work/chunks"),withIntermediateDirectories:true)
        locations[id] = try validatedDirectory(folder, beneath: root)
        let rec = Recording(id:id,title:String(title.prefix(300)),platform:String(platform.prefix(30)),createdAt:isoNow(),micEnabled:mic,participants:Array(Set(participants.filter { !$0.isEmpty }.prefix(64).map { String($0.prefix(80)) })).sorted())
        try save(rec); return rec
    } }
    func checkSpace(_ url: URL, required: Int) throws {
        let attrs = try FileManager.default.attributesOfFileSystem(forPath:url.path)
        if let available = attrs[.systemFreeSize] as? NSNumber, available.int64Value < Int64(required) { throw MeetMeError("Not enough free disk space") }
    }
    func workFolder(_ id: String, chunks: Bool = false) throws -> URL { try locked {
        let folder = try folder(id)
        let work = folder.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at:work, withIntermediateDirectories:true)
        let safeWork = try validatedDirectory(work, beneath: folder)
        guard chunks else { return safeWork }
        let chunkFolder = safeWork.appendingPathComponent("chunks", isDirectory: true)
        try FileManager.default.createDirectory(at:chunkFolder, withIntermediateDirectories:true)
        return try validatedDirectory(chunkFolder, beneath: safeWork)
    } }
    func regularFile(_ url: URL, beneath parent: URL, maximumBytes: Int? = nil) throws -> URL {
        let raw = url, resolved = try canonicalURL(url)
        guard raw.path == resolved.path, isDescendant(raw, of: parent) else { throw MeetMeError("Recording path escapes its folder") }
        let values = try raw.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw MeetMeError("Recording file is not a regular file") }
        if let maximumBytes, let size = values.fileSize, size > maximumBytes { throw MeetMeError("Recording metadata is too large") }
        return raw
    }
    private func libraryRoot() throws -> URL {
        guard let path = config.libraryPath else { throw MeetMeError("Choose an available library folder in Settings first") }
        return try validatedDirectory(URL(fileURLWithPath:path, isDirectory:true), beneath:nil)
    }
    private func decodeRecording(in folder: URL) throws -> Recording {
        let meta = try regularFile(folder.appendingPathComponent("meta.json"), beneath:folder, maximumBytes:4 * 1024 * 1024)
        return try JSONDecoder().decode(Recording.self, from:Data(contentsOf:meta))
    }
    private func validatedDirectory(_ url: URL, beneath parent: URL?) throws -> URL {
        let resolved = try canonicalURL(url)
        // The explicitly selected root may use a macOS ancestor alias such as /var.
        // Once canonicalized, every helper-owned child must stay on that exact path:
        // a symlink anywhere below the root changes realpath and is rejected.
        if let parent {
            guard url.path == resolved.path else { throw MeetMeError("Symbolic links are not allowed in the recording library") }
            guard isDescendant(resolved, of:parent) else { throw MeetMeError("Recording path escapes its library") }
        }
        let values = try url.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw MeetMeError("Recording directory is invalid") }
        return resolved
    }
    private func canonicalURL(_ url: URL) throws -> URL {
        // Foundation's URL normalization depends on home-directory aliases. POSIX
        // realpath gives one physical representation, including under Brave's host.
        guard let path = Darwin.realpath(url.path, nil) else { throw MeetMeError("Recording path is unavailable") }
        defer { Darwin.free(path) }
        return URL(fileURLWithPath:String(cString:path))
    }
    private func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let root = parent.path.hasSuffix("/") ? parent.path : parent.path + "/"
        return child.path.hasPrefix(root)
    }
    func dictionary(_ rec: Recording) -> [String:Any] {
        var result = (try? JSONSerialization.jsonObject(with:JSONEncoder().encode(rec))) as? [String:Any] ?? [:]
        result.removeValue(forKey:"chunks"); return result
    }
}
