import Foundation

final class NativeMessaging: @unchecked Sendable {
    private let outputLock = NSLock()
    func read() throws -> [String:Any]? {
        guard let prefix = try readExactly(4,allowEOF:true) else { return nil }
        let length = prefix.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset*8) }
        guard length > 0, length <= 256*1024 else { throw MeetMeError("Native request exceeds the 256 KiB limit") }
        guard let bytes = try readExactly(Int(length),allowEOF:false), let object = try JSONSerialization.jsonObject(with:bytes) as? [String:Any] else { throw MeetMeError("Invalid native JSON request") }
        return object
    }
    private func readExactly(_ count: Int,allowEOF: Bool) throws -> Data? {
        var data = Data()
        while data.count < count {
            guard let chunk = try FileHandle.standardInput.read(upToCount:count-data.count), !chunk.isEmpty else {
                if allowEOF && data.isEmpty { return nil }; throw MeetMeError("Truncated native frame")
            }
            data.append(chunk)
        }
        return data
    }
    func send(_ object: [String:Any]) throws {
        let data = try JSONSerialization.data(withJSONObject:object,options:.sortedKeys)
        guard data.count < 1024*1024 else { throw MeetMeError("Native response too large; request a smaller page") }
        var size = UInt32(data.count).littleEndian
        var payload = withUnsafeBytes(of:&size) { Data($0) }; payload.append(data)
        outputLock.lock(); defer { outputLock.unlock() }
        try FileHandle.standardOutput.write(contentsOf:payload)
    }
    static func log(_ text: String) { try? FileHandle.standardError.write(contentsOf:Data((text+"\n").utf8)) }
}
