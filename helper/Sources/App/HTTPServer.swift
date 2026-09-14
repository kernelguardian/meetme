import Foundation
import Network
import Security

func randomToken() -> String {
    var bytes = [UInt8](repeating:0,count:32)
    guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes) == errSecSuccess else { fatalError("Secure randomness unavailable") }
    return Data(bytes).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
}
final class HTTPServer: @unchecked Sendable {
    let store: RecordingStore
    let origin: String
    let token = randomToken()
    private var listener: NWListener?
    private let queue = DispatchQueue(label:"meetme.http",attributes:.concurrent)
    private let lock = NSLock()
    private var playbackTokens: [String:(String,Date)] = [:]
    private var activeClients = 0
    private let maximumClients = 8
    private var clients: [ObjectIdentifier: HTTPClient] = [:]
    private(set) var port: UInt16 = 0
    var baseURL: String { "http://127.0.0.1:\(port)" }
    init(store: RecordingStore,origin: String) { self.store = store; self.origin = origin }
    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:.any)
        let listener = try NWListener(using:parameters)
        self.listener = listener
        let ready = DispatchSemaphore(value:0)
        var startError: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: self.port = listener.port!.rawValue; ready.signal()
            case .failed(let error): startError = error; ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { connection in
            guard let client = self.makeClient(connection) else { connection.cancel(); return }
            client.start(on:self.queue)
        }
        listener.start(queue:queue)
        guard ready.wait(timeout:.now()+10) == .success else { throw MeetMeError("Local HTTP server startup timed out") }
        if let startError { throw startError }
    }
    func stop() {
        listener?.cancel()
        lock.lock(); let openClients = Array(clients.values); lock.unlock()
        openClients.forEach { $0.close() }
    }
    func playback(id: String) throws -> [String:Any] {
        let rec = try store.library.get(id)
        guard rec.status == "ready" else { throw MeetMeError("Video has not been finalized") }
        let key = randomToken(), expiry = Date().addingTimeInterval(30*60)
        lock.lock(); playbackTokens = playbackTokens.filter { $0.value.1 > Date() }; playbackTokens[key] = (id,expiry); lock.unlock()
        return ["url":baseURL+"/recordings/\(id)/video?token=\(key)","expiresAt":ISO8601DateFormatter().string(from:expiry)]
    }
    func validPlayback(_ token: String,id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let (recording,expiry) = playbackTokens[token] else { return false }
        return recording == id && expiry > Date()
    }
    private func makeClient(_ connection: NWConnection) -> HTTPClient? {
        lock.lock(); defer { lock.unlock() }
        guard activeClients < maximumClients else { return nil }
        let client = HTTPClient(connection:connection,server:self)
        activeClients += 1; clients[ObjectIdentifier(client)] = client
        return client
    }
    fileprivate func releaseClient(_ client: HTTPClient) {
        lock.lock(); defer { lock.unlock() }
        if clients.removeValue(forKey:ObjectIdentifier(client)) != nil { activeClients = max(0, activeClients - 1) }
    }
}
private final class HTTPClient: @unchecked Sendable {
    let connection: NWConnection
    unowned let server: HTTPServer
    var buffer = Data()
    var headerEnd: Int? = nil
    var contentLength = 0
    var method = "", target = ""
    var headers: [String:String] = [:]
    var finished = false
    var released = false
    private let closeLock = NSLock()
    init(connection: NWConnection,server: HTTPServer) { self.connection = connection; self.server = server }
    func start(on queue: DispatchQueue) {
        connection.start(queue:queue)
        queue.asyncAfter(deadline:.now()+60) { [weak self] in self?.close() }
        receive()
    }
    func receive() {
        connection.receive(minimumIncompleteLength:1,maximumLength:65536) { data,_,complete,error in
            if let data { self.buffer.append(data) }
            if self.buffer.count > 32*1024*1024+16384 { self.respond(413,["error":"Request too large"]); return }
            if self.headerEnd == nil {
                if let range = self.buffer.range(of:Data("\r\n\r\n".utf8)) {
                    guard range.upperBound <= 16384, self.parseHeaders(Data(self.buffer[..<range.lowerBound])) else { self.respond(400,["error":"Invalid request"]); return }
                    self.headerEnd = range.upperBound
                } else if self.buffer.count > 16384 { self.respond(431,["error":"Headers too large"]); return }
            }
            if let headerEnd = self.headerEnd, self.buffer.count >= headerEnd+self.contentLength {
                guard self.buffer.count == headerEnd+self.contentLength else { self.respond(400,["error":"Pipelining is unsupported"]); return }
                self.route(body:Data(self.buffer[headerEnd...])); return
            }
            if error != nil || complete { self.close(); return }
            self.receive()
        }
    }
    func parseHeaders(_ data: Data) -> Bool {
        guard let text = String(data:data,encoding:.utf8) else { return false }
        let lines = text.components(separatedBy:"\r\n")
        let first = lines[0].split(separator:" ",omittingEmptySubsequences:false)
        guard first.count == 3, first[2] == "HTTP/1.1" else { return false }
        method = String(first[0]); target = String(first[1])
        for line in lines.dropFirst() {
            guard let index = line.firstIndex(of:":") else { return false }
            let name = line[..<index].lowercased(), value = line[line.index(after:index)...].trimmingCharacters(in:.whitespaces)
            guard headers[name] == nil else { return false }; headers[name] = value
        }
        guard headers["host"] == "127.0.0.1:\(server.port)", headers["transfer-encoding"] == nil else { return false }
        if let origin = headers["origin"], origin != server.origin { return false }
        if let length = headers["content-length"] {
            guard let n = Int(length), n >= 0, n <= 32*1024*1024 else { return false }; contentLength = n
        }
        return true
    }
    func route(body: Data) {
        guard let url = URLComponents(string:target), url.scheme == nil, url.host == nil,
              !url.percentEncodedPath.contains("%"), !url.path.contains("..") else { respond(400,["error":"Invalid path"]); return }
        let parts = url.path.split(separator:"/").map(String.init)
        if method == "OPTIONS" {
            guard headers["origin"] == server.origin else { respond(403,["error":"Forbidden origin"]); return }
            send(status:204,data:Data(),extra:["Access-Control-Allow-Methods":"POST, GET, HEAD, OPTIONS","Access-Control-Allow-Headers":"Authorization, Content-Type, X-Content-SHA256, X-Chunk-Length, Range","Access-Control-Max-Age":"600"]); return
        }
        if parts.count == 4, parts[0] == "recordings", parts[2] == "chunks", method == "POST" {
            guard headers["authorization"] == "Bearer \(server.token)" else { respond(401,["error":"Unauthorized"]); return }
            guard let seq = Int(parts[3]), let hash = headers["x-content-sha256"], let length = headers["x-chunk-length"].flatMap(Int.init) else { respond(400,["error":"Missing chunk integrity headers"]); return }
            do { respond(200,try server.store.append(id:parts[1],sequence:seq,data:body,checksum:hash,declaredLength:length)) }
            catch { respond(409,["error":error.localizedDescription]) }; return
        }
        if parts.count == 3, parts[0] == "recordings", parts[2] == "video", method == "GET" || method == "HEAD" {
            let playback = url.queryItems?.first(where: { $0.name == "token" })?.value ?? ""
            guard server.validPlayback(playback,id:parts[1]) else { respond(401,["error":"Playback token expired or invalid"]); return }
            do {
                let folder = try server.store.library.folder(parts[1])
                try serveFile(server.store.library.regularFile(folder.appendingPathComponent("video.webm"), beneath:folder))
            }
            catch { respond(404,["error":"Video unavailable"] ) }; return
        }
        respond(404,["error":"Not found"])
    }
    func respond(_ code: Int,_ object: [String:Any]) { send(status:code,data:(try? JSONSerialization.data(withJSONObject:object)) ?? Data(),extra:["Content-Type":"application/json"]) }
    func head(status: Int,length: UInt64,extra: [String:String]) -> Data {
        let reason = [200:"OK",204:"No Content",206:"Partial Content",400:"Bad Request",401:"Unauthorized",403:"Forbidden",404:"Not Found",409:"Conflict",413:"Payload Too Large",416:"Range Not Satisfiable",431:"Request Header Fields Too Large"][status] ?? "Error"
        var fields = ["Content-Length":String(length),"Connection":"close","Cache-Control":"no-store","X-Content-Type-Options":"nosniff","Access-Control-Allow-Origin":server.origin,"Vary":"Origin","Access-Control-Expose-Headers":"Content-Range, Accept-Ranges"]
        fields.merge(extra,uniquingKeysWith: { _,new in new })
        return Data(("HTTP/1.1 \(status) \(reason)\r\n"+fields.map { "\($0.key): \($0.value)" }.joined(separator:"\r\n")+"\r\n\r\n").utf8)
    }
    func send(status: Int,data: Data,extra: [String:String] = [:]) {
        guard !finished else { return }; finished = true
        var payload = head(status:status,length:UInt64(data.count),extra:extra); if method != "HEAD" { payload.append(data) }
        connection.send(content:payload,completion:.contentProcessed { _ in self.close() })
    }
    func serveFile(_ file: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath:file.path)
        guard let size = (attributes[.size] as? NSNumber)?.uint64Value, size > 0 else { throw MeetMeError("Empty video") }
        var start: UInt64 = 0, end = size-1, status = 200
        if let range = headers["range"] {
            guard let parsed = Self.parseRange(range,size:size) else { send(status:416,data:Data(),extra:["Content-Range":"bytes */\(size)"]); return }
            start = parsed.0; end = parsed.1; status = 206
        }
        var extra = ["Content-Type":"video/webm","Accept-Ranges":"bytes"]
        if status == 206 { extra["Content-Range"] = "bytes \(start)-\(end)/\(size)" }
        let handle = try FileHandle(forReadingFrom:file); try handle.seek(toOffset:start)
        finished = true
        connection.send(content:head(status:status,length:end-start+1,extra:extra),completion:.contentProcessed { error in
            if error != nil || self.method == "HEAD" { try? handle.close(); self.close() }
            else { self.stream(handle,remaining:end-start+1) }
        })
    }
    static func parseRange(_ value: String,size: UInt64) -> (UInt64,UInt64)? {
        guard size > 0, value.hasPrefix("bytes="), !value.contains(",") else { return nil }
        let parts = value.dropFirst(6).split(separator:"-",omittingEmptySubsequences:false)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty { guard let suffix = UInt64(parts[1]), suffix > 0 else { return nil }; return (size-min(size,suffix),size-1) }
        guard let start = UInt64(parts[0]), start < size else { return nil }
        let end: UInt64
        if parts[1].isEmpty { end = size-1 } else { guard let parsed = UInt64(parts[1]), parsed >= start else { return nil }; end = min(parsed,size-1) }
        return (start,end)
    }
    func stream(_ file: FileHandle,remaining: UInt64) {
        guard remaining > 0 else { try? file.close(); close(); return }
        do {
            guard let data = try file.read(upToCount:Int(min(262144,remaining))), !data.isEmpty else { try? file.close(); close(); return }
            connection.send(content:data,completion:.contentProcessed { error in
                if error != nil { try? file.close(); self.close() }
                else { self.stream(file,remaining:remaining-UInt64(data.count)) }
            })
        } catch { try? file.close(); close() }
    }
    func close() {
        closeLock.lock(); defer { closeLock.unlock() }
        guard !released else { return }
        released = true
        connection.cancel()
        server.releaseClient(self)
    }
}
