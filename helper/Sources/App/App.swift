import Foundation
import AppKit

actor Coordinator {
    let library: Library
    let store: RecordingStore
    let server: HTTPServer
    let jobs: Jobs
    init(library: Library,store: RecordingStore,server: HTTPServer) { self.library = library; self.store = store; self.server = server; self.jobs = Jobs(library) }
    func boot() async { await jobs.start() }
    func handle(_ request: [String:Any]) async throws -> [String:Any] {
        guard let command = request["command"] as? String else { throw MeetMeError("Missing command") }
        func id() throws -> String { guard let id = request["recordingId"] as? String else { throw MeetMeError("Missing recordingId") }; return id }
        switch command {
        case "hello":
            var result: [String:Any] = ["baseURL":server.baseURL,"token":server.token,"model":library.model,"engine":library.engine.rawValue,"protocolVersion":1,"ffmpegAvailable":MediaPrepare.available()]
            result["libraryPath"] = library.libraryPath ?? NSNull() as Any
            return result
        case "status": return await jobs.state()
        case "settings":
            let engine = (request["engine"] as? String).map(Transcribe.Engine.parse) ?? library.engine
            let language = request["model"] as? String ?? library.model
            let variant = request["whisperVariant"] as? String ?? library.whisperVariant
            if request["engine"] != nil || request["model"] != nil || request["whisperVariant"] != nil {
                try await Transcribe.validate(engine:engine,language:language,variant:variant)
                try library.setWhisperVariant(variant); try library.setEngine(engine); try library.setModel(language)
            }
            return ["model":library.model,"engine":library.engine.rawValue,"whisperVariant":library.whisperVariant,
                    "engines":await Transcribe.engines(),"whisperVariants":WhisperTranscribe.variants,
                    "libraryPath":library.libraryPath ?? NSNull() as Any]
        case "chooseFolder":
            let selection = await FolderPicker.choose()
            guard let selection else { throw MeetMeError("Folder selection cancelled") }
            try library.selectFolder(selection); return ["libraryPath":selection.path]
        case "list":
            let offset = max(0,request["offset"] as? Int ?? 0), limit = min(100,max(1,request["limit"] as? Int ?? 30)), query = (request["query"] as? String ?? "").lowercased()
            let all = library.all().filter { rec in
                if query.isEmpty || rec.title.lowercased().contains(query) || rec.platform.lowercased().contains(query) { return true }
                guard let folder = try? library.folder(rec.id) else { return false }
                for name in ["transcript.txt","summary.md"] { if let text = try? String(contentsOf:folder.appendingPathComponent(name),encoding:.utf8), text.lowercased().contains(query) { return true } }
                return false
            }
            return ["items":all.dropFirst(offset).prefix(limit).map(library.dictionary),"total":all.count]
        case "create":
            guard MediaPrepare.available() else { throw MeetMeError("FFmpeg and ffprobe are required. Run the installer or configure their paths.") }
            await jobs.pause()
            do {
                let rec = try library.create(title:request["title"] as? String ?? "Untitled meeting",platform:request["platform"] as? String ?? "browser",mic:request["micEnabled"] as? Bool ?? false,participants:request["participants"] as? [String] ?? [])
                return library.dictionary(rec)
            } catch { await jobs.resume(); throw error }
        case "finalize":
            let recordingId = try id()
            guard let count = request["chunkCount"] as? Int, let bytes = request["totalBytes"] as? Int else { throw MeetMeError("Finalization requires chunkCount and totalBytes") }
            let store = self.store
            await jobs.pause()
            do {
                let rec = try await Task.detached { try store.finalize(id:recordingId,expectedCount:count,expectedBytes:bytes) }.value
                await jobs.resume(); return library.dictionary(rec)
            } catch { await jobs.resume(); throw error }
        case "abort":
            let rec = try store.abort(id:id(),reason:request["error"] as? String ?? "Capture interrupted")
            await jobs.resume(); return library.dictionary(rec)
        case "recover":
            let recordingId = try id(), store = self.store
            await jobs.pause()
            do {
                let rec = try await Task.detached { try store.finalize(id:recordingId,expectedCount:nil,expectedBytes:nil,recovery:true) }.value
                await jobs.resume(); return library.dictionary(rec)
            } catch { await jobs.resume(); throw error }
        case "detail":
            let recordingId = try id(), rec = try library.get(recordingId), folder = try library.folder(recordingId)
            let segments = (try? JSONDecoder().decode([TranscriptSegment].self,from:Data(contentsOf:folder.appendingPathComponent("transcript.json")))) ?? []
            let offset = max(0,request["offset"] as? Int ?? 0), limit = min(300,max(1,request["limit"] as? Int ?? 200))
            let page = Array(segments.dropFirst(offset).prefix(limit))
            let encoded = try JSONSerialization.jsonObject(with:JSONEncoder().encode(page))
            let summary = (try? String(contentsOf:folder.appendingPathComponent("summary.md"),encoding:.utf8)) ?? ""
            return ["recording":library.dictionary(rec),"segments":encoded,"totalSegments":segments.count,"summary":String(summary.prefix(150000))]
        case "playback": return try server.playback(id:id())
        case "reprocess": return library.dictionary(try await jobs.enqueue(id:id(),stage:request["stage"] as? String ?? "all",language:request["language"] as? String))
        case "downloadModel": return try await jobs.download()
        case "cancelDownload": return await jobs.cancelDownload()
        case "stopProcessing": return try await jobs.stopJob(id:id())
        case "cleanup": return library.dictionary(try store.cleanup(id:id()))
        default: throw MeetMeError("Unknown command: \(command)")
        }
    }
    func shutdown() async { server.stop(); await jobs.pause() }
}

@main struct MeetMeMain {
    // Native messaging still owns the process lifetime, but AppKit owns its main
    // thread. An async command-line entry point does not establish the AppKit
    // event loop required by NSOpenPanel and its window-server connections.
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = NativeApplicationDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }

    static func runHost() async {
        do {
            guard let origin = CommandLine.arguments.dropFirst().first, origin.hasPrefix("chrome-extension://"),
                  let url = URL(string:origin), let host = url.host, host.count == 32, host.allSatisfy({ ("a"..."p").contains(String($0)) }), url.path == "/" || url.path.isEmpty else { throw MeetMeError("Launch through the registered Brave native messaging host") }
            let library = try Library(), store = RecordingStore(library)
            let server = HTTPServer(store:store,origin:"chrome-extension://\(host)")
            try server.start()
            let coordinator = Coordinator(library:library,store:store,server:server), messaging = NativeMessaging()
            await coordinator.boot()
            while true {
                let request: [String:Any]
                do { guard let next = try await Task.detached(operation: { try messaging.read() }).value else { break }; request = next }
                catch { NativeMessaging.log(error.localizedDescription); break }
                let requestId = request["id"] as? String ?? ""
                do {
                    let result = try await coordinator.handle(request)
                    try messaging.send(["id":requestId,"ok":true,"result":result])
                } catch { try? messaging.send(["id":requestId,"ok":false,"error":error.localizedDescription]) }
            }
            server.stop()
            await coordinator.shutdown()
        } catch { NativeMessaging.log(error.localizedDescription) }
    }
}

@MainActor
private final class NativeApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task.detached {
            await MeetMeMain.runHost()
            await MainActor.run { NSApplication.shared.terminate(nil) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@MainActor
private enum FolderPicker {
    static func choose() async -> URL? {
        await withCheckedContinuation { continuation in
            let panel = NSOpenPanel()
            panel.title = "Choose your MeetMe recording library"
            panel.message = "Choose a local folder for recordings, transcripts, and summaries."
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
            NSApplication.shared.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
    }
}
