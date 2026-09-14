import XCTest
@testable import App

final class StorageTests: XCTestCase {
    private var temporary: URL!
    private var library: Library!
    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        library = try Library(configDirectory:temporary.appendingPathComponent("config"),initialLibrary:temporary.appendingPathComponent("library"))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at:temporary) }
    func testChunksAreOrderedAndDuplicateSafe() throws {
        let rec = try library.create(title:"Test",platform:"meet",mic:false), store = RecordingStore(library)
        let data = Data("recording data".utf8)
        XCTAssertThrowsError(try store.append(id:rec.id,sequence:1,data:data,checksum:sha256(data),declaredLength:data.count))
        _ = try store.append(id:rec.id,sequence:0,data:data,checksum:sha256(data),declaredLength:data.count)
        _ = try store.append(id:rec.id,sequence:0,data:data,checksum:sha256(data),declaredLength:data.count)
        XCTAssertEqual(try library.get(rec.id).chunkCount,1)
        XCTAssertEqual(try library.get(rec.id).totalBytes,data.count)
        let conflicting = Data("different data".utf8)
        XCTAssertThrowsError(try store.append(id:rec.id,sequence:0,data:conflicting,checksum:sha256(conflicting),declaredLength:conflicting.count))
    }
    func testInvalidChecksumDoesNotCommit() throws {
        let rec = try library.create(title:"Test",platform:"meet",mic:false)
        XCTAssertThrowsError(try RecordingStore(library).append(id:rec.id,sequence:0,data:Data([1]),checksum:"invalid",declaredLength:1))
        XCTAssertEqual(try library.get(rec.id).chunkCount,0)
    }
    func testRestartMarksCaptureIncompleteAndRequeuesRunningJob() throws {
        let rec = try library.create(title:"Interrupted",platform:"meet",mic:false)
        _ = try library.update(rec.id) { $0.jobStatus = "running" }
        let reopened = try Library(configDirectory:temporary.appendingPathComponent("config"),initialLibrary:temporary.appendingPathComponent("library"))
        XCTAssertEqual(try reopened.get(rec.id).status,"incomplete")
        XCTAssertEqual(try reopened.get(rec.id).jobStatus,"queued")
    }
    func testOpaqueIDsRejectPaths() {
        XCTAssertThrowsError(try library.folder("../../etc"))
    }
    func testSingleActiveRecording() throws {
        _ = try library.create(title:"One",platform:"meet",mic:false)
        XCTAssertThrowsError(try library.create(title:"Two",platform:"meet",mic:false))
    }
    func testFinalizationMismatchKeepsCaptureActive() throws {
        let rec = try library.create(title:"Test",platform:"meet",mic:false), store = RecordingStore(library), data = Data([1,2])
        _ = try store.append(id:rec.id,sequence:0,data:data,checksum:sha256(data),declaredLength:2)
        XCTAssertThrowsError(try store.finalize(id:rec.id,expectedCount:2,expectedBytes:2))
        XCTAssertEqual(try library.get(rec.id).status,"recording")
    }
    func testSRTTimestampRounding() {
        XCTAssertEqual(Jobs.timestamp(3661.234),"01:01:01,234")
        XCTAssertEqual(Jobs.timestamp(-1),"00:00:00,000")
        XCTAssertEqual(Jobs.timestamp(59.9999),"00:01:00,000")
    }
    func testLegacyWhisperConfigurationMigratesToEnglishUS() throws {
        let config = temporary.appendingPathComponent("config")
        try FileManager.default.createDirectory(at:config,withIntermediateDirectories:true)
        try Data("{\"model\":\"openai_whisper-base\"}".utf8).write(to:config.appendingPathComponent("config.json"))
        let migrated = try Library(configDirectory:config,initialLibrary:temporary.appendingPathComponent("library"))
        XCTAssertEqual(migrated.model,"en-US")
    }
    func testLibraryStoresLocaleCandidatesAndRejectsMalformedValues() throws {
        try library.setModel("fr-FR")
        XCTAssertEqual(library.model,"fr-FR")
        XCTAssertThrowsError(try library.setModel(""))
        XCTAssertThrowsError(try library.setModel(String(repeating:"x",count:65)))
    }
}
