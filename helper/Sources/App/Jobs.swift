import Foundation

actor Jobs {
    let library: Library
    private var worker: Task<Void,Never>?
    private var downloadTask: Task<Void,Never>?
    private var suspended = false
    private var downloading = false
    private var downloadError: String? = nil
    private var downloadProgress: Double? = nil
    init(_ library: Library) { self.library = library }
    func pause() async {
        suspended = true
        worker?.cancel()
        await worker?.value
        worker = nil
        downloadTask?.cancel()
        await downloadTask?.value
        downloadTask = nil
        downloading = false
    }
    func resume() { suspended = false; start() }
    func start() {
        guard worker == nil, !suspended, !library.all().contains(where: { $0.status == "recording" || $0.status == "finalizing" }) else { return }
        let library = self.library
        worker = Task.detached { [weak self] in
            // A `let` so the @Sendable progress sink captures an immutable reference.
            let jobs = self
            while !Task.isCancelled {
                guard let rec = library.all().reversed().first(where: { $0.status == "ready" && $0.jobStatus == "queued" }) else { break }
                let id = rec.id
                do { try await Self.process(rec,library:library) { stage, fraction in
                        Task { await jobs?.setJobProgress(id:id,stage:stage,fraction:fraction) }
                    } }
                catch is CancellationError {
                    // A recording starting or a folder change re-queues the job; an
                    // explicit Stop leaves it alone until the user asks again.
                    if await jobs?.consumeStopRequest(id) == true {
                        _ = try? library.update(id) { $0.jobStatus = "stopped"; $0.error = nil }
                    } else {
                        _ = try? library.update(id) { $0.jobStatus = "queued"; $0.error = "Processing interrupted; will resume after recording." }
                    }
                    await jobs?.clearJobProgress(id:id)
                    break
                }
                catch { _ = try? library.update(rec.id) { $0.jobStatus = "failed"; $0.error = error.localizedDescription } }
                await jobs?.clearJobProgress(id:id)
            }
            await jobs?.finished()
        }
    }
    private var jobProgress: (id: String, stage: String, fraction: Double)? = nil
    private var stopRequests: Set<String> = []
    private func setJobProgress(id: String, stage: String, fraction: Double) { jobProgress = (id, stage, fraction) }
    private func clearJobProgress(id: String) { if jobProgress?.id == id { jobProgress = nil } }
    private func consumeStopRequest(_ id: String) -> Bool { stopRequests.remove(id) != nil }

    /// Stops transcription or summarisation for one recording. Anything already written
    /// is kept, and other queued recordings carry on.
    func stopJob(id: String) async throws -> [String:Any] {
        let rec = try library.get(id)
        guard ["queued","running"].contains(rec.jobStatus) else { return ["stopped":false,"jobStatus":rec.jobStatus] }
        if rec.jobStatus == "queued" {
            // Never started, so it is enough to take it out of the queue.
            _ = try library.update(id) { $0.jobStatus = "stopped"; $0.error = nil }
            return ["stopped":true,"jobStatus":"stopped"]
        }
        stopRequests.insert(id)
        worker?.cancel()
        await worker?.value
        clearJobProgress(id: id)
        start()
        return ["stopped":true,"jobStatus":(try? library.get(id).jobStatus) ?? "stopped"]
    }
    private func finished() { worker = nil; if !suspended && library.all().contains(where: { $0.status == "ready" && $0.jobStatus == "queued" }) { start() } }
    func enqueue(id: String,stage: String,language: String? = nil) async throws -> Recording {
        guard ["all","transcribe","summary"].contains(stage) else { throw MeetMeError("Unknown processing stage") }
        let rec = try library.get(id)
        guard rec.status == "ready" else { throw MeetMeError("Finalize or recover this recording first") }
        // Validate before the already-queued short circuit, so an unusable language is
        // always reported rather than silently accepted.
        // Correcting a wrong auto-detection re-runs this recording in the chosen
        // language, leaving the global setting alone.
        if let language, !language.isEmpty {
            try await Transcribe.validate(engine:library.engine,language:language,variant:library.whisperVariant)
        }
        if rec.jobStatus == "running" || rec.jobStatus == "queued" { return rec }
        let updated = try library.update(id) {
            $0.jobStatus = "queued"; $0.jobStage = stage; $0.error = nil
            if let language { $0.languageOverride = language.isEmpty ? nil : language }
        }
        start(); return updated
    }
    func download() throws -> [String:Any] {
        guard !downloading else { return ["queued":true] }
        guard !suspended, !library.all().contains(where: { $0.status == "recording" || $0.jobStatus == "running" }) else { throw MeetMeError("Wait until recording and processing finish before downloading a model") }
        downloading = true; downloadError = nil; downloadProgress = 0
        let model = library.model, root = library.modelRoot, engine = library.engine, variant = library.whisperVariant
        downloadTask = Task.detached { [weak self] in
            // Bound to a `let` so the @Sendable progress closure captures an immutable
            // actor reference rather than the mutable `self` var.
            let jobs = self
            do {
                try await Transcribe.download(engine:engine,language:model,variant:variant,modelRoot:root) { fraction in
                    Task { await jobs?.setDownloadProgress(fraction) }
                }
                await jobs?.downloadFinished(nil)
            }
            catch is CancellationError { await self?.downloadCancelled() }
            catch { await self?.downloadFinished(error.localizedDescription) }
        }
        return ["queued":true]
    }
    func cancelDownload() async -> [String:Any] {
        guard downloading, let task = downloadTask else { return ["cancelled":false] }
        task.cancel()
        await task.value
        downloadTask = nil
        downloading = false; downloadProgress = nil; downloadError = nil
        return ["cancelled":true]
    }
    private func setDownloadProgress(_ fraction: Double) { if downloading { downloadProgress = fraction } }
    private func downloadFinished(_ error: String?) { downloading = false; downloadProgress = nil; downloadError = error }
    private func downloadCancelled() { downloading = false; downloadProgress = nil; downloadError = nil }
    func state() async -> [String:Any] {
        var state: [String:Any] = ["processing":library.all().contains(where: { $0.jobStatus == "running" }),"modelReady":await Transcribe.isReady(engine:library.engine,language:library.model,variant:library.whisperVariant,modelRoot:library.modelRoot),"summaryAvailable":Summarize.availability,"downloading":downloading,"engine":library.engine.rawValue,"whisperVariant":library.whisperVariant]
        if let error = downloadError { state["downloadError"] = error }
        if let progress = downloadProgress { state["downloadProgress"] = progress }
        // The library page watches this so choosing a different folder reloads the list.
        state["libraryPath"] = library.libraryPath ?? NSNull() as Any
        if let progress = jobProgress {
            state["jobRecordingId"] = progress.id
            state["jobStage"] = progress.stage
            state["jobProgress"] = progress.fraction
        }
        state["recordingId"] = library.all().first(where: { $0.status == "recording" })?.id ?? NSNull() as Any
        return state
    }
    nonisolated static func process(_ rec: Recording,library: Library,progress: (@Sendable (String, Double) -> Void)? = nil) async throws {
        try Task.checkCancellation()
        let engine = library.engine, variant = library.whisperVariant
        let language = rec.languageOverride ?? library.model
        _ = try library.update(rec.id) { $0.jobStatus = "running"; $0.error = nil; $0.summarySkipped = nil; $0.model = engine.rawValue + ":" + (engine == .whisper ? variant : language) }
        let folder = try library.folder(rec.id), work = folder.appendingPathComponent("work")
        try FileManager.default.createDirectory(at:work,withIntermediateDirectories:true)
        let audio = work.appendingPathComponent("audio.wav")
        let video = folder.appendingPathComponent("video.webm")
        var segments: [TranscriptSegment]
        var spoken: String
        if rec.jobStage == "summary" {
            segments = try JSONDecoder().decode([TranscriptSegment].self,from:Data(contentsOf:folder.appendingPathComponent("transcript.json")))
            spoken = rec.language ?? language
        } else {
            try MediaPrepare.audio(video:video,output:audio)
            try Task.checkCancellation()
            let outcome = try await Transcribe.run(audio:audio,engine:engine,language:language,variant:variant,modelRoot:library.modelRoot,
                                                   duration:rec.duration ?? 0) { fraction in progress?("transcribe", fraction) }
            segments = outcome.segments; spoken = outcome.language
            try Task.checkCancellation()
            try durableWrite(JSONEncoder().encode(segments),to:folder.appendingPathComponent("transcript.json"))
            try durableWrite(Data(segments.map(\.text).joined(separator:"\n").utf8),to:folder.appendingPathComponent("transcript.txt"))
            let srt = segments.enumerated().map { "\($0.offset+1)\n\(timestamp($0.element.start)) --> \(timestamp($0.element.end))\n\($0.element.text)\n" }.joined(separator:"\n")
            try durableWrite(Data(srt.utf8),to:folder.appendingPathComponent("transcript.srt"))
            _ = try library.update(rec.id) { $0.hasTranscript = true; $0.language = spoken; $0.jobStage = rec.jobStage == "all" ? "summary" : "transcribe" }
        }
        if rec.jobStage != "transcribe" {
            try Task.checkCancellation()
            var source = segments
            var skipped: String? = nil
            if !Summarize.supportsLanguage(spoken) {
                if engine == .whisper {
                    // Apple Intelligence cannot read this language, so summarise Whisper's
                    // English rendering of the same audio; timings still match the recording.
                    if !FileManager.default.fileExists(atPath:audio.path) { try MediaPrepare.audio(video:video,output:audio) }
                    let english = try await Transcribe.translateToEnglish(audio:audio,engine:engine,language:spoken,variant:variant,modelRoot:library.modelRoot,
                                                                          duration:rec.duration ?? 0) { fraction in progress?("translate", fraction) }
                    try durableWrite(Data(english.map(\.text).joined(separator:"\n").utf8),to:folder.appendingPathComponent("transcript.en.txt"))
                    source = english
                    _ = try library.update(rec.id) { $0.hasTranslation = true }
                } else {
                    skipped = "Apple Intelligence cannot summarise \(languageName(spoken)). Switch the engine to Whisper in Settings to get an English summary."
                }
            }
            if let skipped {
                _ = try library.update(rec.id) { $0.summarySkipped = skipped }
            } else {
                let summary = try await Summarize.run(segments:source,work:work) { fraction in progress?("summary", fraction) }
                try durableWrite(Data(summary.utf8),to:folder.appendingPathComponent("summary.md"))
                _ = try library.update(rec.id) { $0.hasSummary = true }
            }
        }
        _ = try library.update(rec.id) { $0.jobStatus = "completed"; $0.error = nil }
        try? FileManager.default.removeItem(at:audio)
    }
    nonisolated static func languageName(_ code: String) -> String {
        let normalized = code.replacingOccurrences(of:"_",with:"-")
        return Locale.current.localizedString(forIdentifier:normalized)
            ?? Locale.current.localizedString(forLanguageCode:normalized)
            ?? normalized
    }
    nonisolated static func timestamp(_ seconds: Double) -> String {
        let value = Int((max(0,seconds)*1000).rounded()), hours = value/3600000, minutes = (value/60000)%60, secs = (value/1000)%60, millis = value%1000
        return String(format:"%02d:%02d:%02d,%03d",hours,minutes,secs,millis)
    }
}
