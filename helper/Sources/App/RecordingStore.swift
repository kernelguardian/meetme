import Foundation

final class RecordingStore: @unchecked Sendable {
    let library: Library
    init(_ library: Library) { self.library = library }
    func append(id: String, sequence: Int, data: Data, checksum: String, declaredLength: Int) throws -> [String:Any] { try library.locked {
        guard sequence >= 0, data.count > 0, data.count <= 32*1024*1024, data.count == declaredLength, sha256(data) == checksum.lowercased() else { throw MeetMeError("Invalid chunk size or checksum") }
        var rec = try library.get(id)
        if let receipt = rec.chunks[String(sequence)] {
            guard receipt.bytes == data.count, receipt.checksum == checksum.lowercased() else { throw MeetMeError("Conflicting duplicate chunk") }
            return ["sequence":sequence,"nextSequence":rec.chunkCount,"bytes":rec.totalBytes]
        }
        guard rec.status == "recording", sequence == rec.chunkCount else { throw MeetMeError("Unexpected chunk sequence or recording is not active") }
        let folder = try library.folder(id)
        try library.checkSpace(folder,required:data.count+128*1024*1024)
        let chunk = try library.workFolder(id, chunks:true).appendingPathComponent("\(sequence).bin")
        if FileManager.default.fileExists(atPath:chunk.path) {
            let safeChunk = try library.regularFile(chunk, beneath:try library.workFolder(id, chunks:true))
            guard sha256(try Data(contentsOf:safeChunk)) == checksum.lowercased() else { throw MeetMeError("Conflicting uncommitted chunk") }
        } else { try durableWrite(data,to:chunk) }
        rec.chunks[String(sequence)] = ChunkReceipt(bytes:data.count,checksum:checksum.lowercased())
        rec.chunkCount += 1; rec.totalBytes += data.count
        try library.save(rec)
        return ["sequence":sequence,"nextSequence":rec.chunkCount,"bytes":rec.totalBytes]
    } }
    func finalize(id: String, expectedCount: Int?, expectedBytes: Int?, recovery: Bool = false) throws -> Recording {
        var rec = try library.locked { () throws -> Recording in
            var rec = try library.get(id)
            if rec.status == "ready" { return rec }
            guard rec.status == "recording" || (recovery && ["incomplete","failed"].contains(rec.status)) else { throw MeetMeError("Recording cannot be finalized in its current state") }
            guard rec.chunkCount > 0, expectedCount == nil || rec.chunkCount == expectedCount, expectedBytes == nil || rec.totalBytes == expectedBytes else { throw MeetMeError("Final chunk count or byte total does not match committed data") }
            rec.status = "finalizing"; try library.save(rec); return rec
        }
        if rec.status == "ready" { return rec }
        let folder = try library.folder(id)
        do {
            try library.checkSpace(folder,required:rec.totalBytes*2+128*1024*1024)
            let work = try library.workFolder(id)
            let input = work.appendingPathComponent("assembled-\(UUID().uuidString).webm")
            guard FileManager.default.createFile(atPath:input.path,contents:nil) else { throw MeetMeError("Cannot create assembled recording") }
            let handle = try FileHandle(forWritingTo:input)
            do {
                for seq in 0..<rec.chunkCount {
                    let chunk = try library.regularFile(try library.workFolder(id, chunks:true).appendingPathComponent("\(seq).bin"), beneath:try library.workFolder(id, chunks:true))
                    let data = try Data(contentsOf:chunk)
                    guard let receipt = rec.chunks[String(seq)], data.count == receipt.bytes, sha256(data) == receipt.checksum else { throw MeetMeError("Committed chunk \(seq) failed integrity validation") }
                    try handle.write(contentsOf:data)
                }
                try handle.synchronize(); try handle.close()
            } catch { try? handle.close(); throw error }
            let duration = try MediaPrepare.finalize(input:input,output:folder.appendingPathComponent("video.webm"))
            rec = try library.update(id) { $0.status = "ready"; $0.duration = duration; $0.endedAt = isoNow(); $0.jobStatus = "queued"; $0.jobStage = "all"; $0.error = recovery ? "Recovered recording may be truncated at the last committed chunk." : nil }
            // Keep committed chunks until all generated artifacts have been verified or the user cleans recovery files.
            try? FileManager.default.removeItem(at:input)
            return rec
        } catch {
            _ = try? library.update(id) { $0.status = "incomplete"; $0.error = error.localizedDescription }
            throw error
        }
    }
    func abort(id: String, reason: String) throws -> Recording { try library.update(id) { if $0.status != "ready" { $0.status = "incomplete"; $0.endedAt = isoNow(); $0.error = String(reason.prefix(2000)) } } }
    func cleanup(id: String) throws -> Recording { try library.locked {
        let rec = try library.get(id)
        guard rec.status == "ready", rec.jobStatus != "running", rec.jobStatus != "queued" else { throw MeetMeError("Only idle, finalized recordings can be cleaned") }
        let work = try library.workFolder(id)
        if FileManager.default.fileExists(atPath:work.path) { try FileManager.default.removeItem(at:work) }
        try FileManager.default.createDirectory(at:work,withIntermediateDirectories:true)
        return rec
    } }
}
