import XCTest
@testable import App

/// Covers the two contracts that silently broke summarisation for a real recording:
/// how input size is estimated, and which citation shapes count as evidence.
final class SummarizeTests: XCTestCase {

    // A scalar-count floor previously made this "one character, one token", so an
    // English transcript measured about three times the byte-based estimate. Chunk
    // summaries then looked larger than the budget, reduction could not converge,
    // and the summary failed with a context error.
    func testLatinTextIsNotCountedAsOneTokenPerCharacter() {
        let english = String(repeating: "a", count: 1_781)
        XCTAssertEqual(Summarize.estimatedTokens(english), 594)
        XCTAssertLessThan(Summarize.estimatedTokens(english), english.count)
    }

    // Indic and CJK characters are three UTF-8 bytes each, so the byte estimate lands
    // near one token per character for them without inflating Latin text.
    func testThreeByteScriptsCountNearOneTokenPerCharacter() {
        for scalar in ["\u{0D15}", "\u{4E2D}"] {
            let text = String(repeating: scalar, count: 1_000)
            XCTAssertEqual(Summarize.estimatedTokens(text), 1_000)
        }
    }

    func testEmptyTextStillCostsAtLeastOneToken() {
        XCTAssertEqual(Summarize.estimatedTokens(""), 1)
    }

    // Segments are rendered to the model as ranges, so it cites them back as ranges.
    // Accepting only a lone [HH:MM:SS] rejected every citation the model produced.
    func testRangeCitationsAreAcceptedInAnyDash() {
        let segments = [TranscriptSegment(start: 90, end: 120, text: "spoken words")]
        for citation in ["[00:01:33]", "[00:01:33-00:01:38]", "[00:01:33–00:01:38]", "[00:01:33 — 00:01:38]"] {
            XCTAssertTrue(Summarize.validProvenance(in: "A claim \(citation)", segments: segments), citation)
        }
    }

    func testCitationOutsideEverySegmentIsRejected() {
        let segments = [TranscriptSegment(start: 90, end: 120, text: "spoken words")]
        XCTAssertFalse(Summarize.validProvenance(in: "A claim [00:09:59]", segments: segments))
    }

    func testSummaryWithoutAnyCitationIsRejected() {
        let segments = [TranscriptSegment(start: 0, end: 60, text: "spoken words")]
        XCTAssertFalse(Summarize.validProvenance(in: "A claim with no evidence", segments: segments))
    }

    // An out-of-range component must fail the whole parse rather than be skipped,
    // so a malformed citation can never pass as evidence.
    func testMalformedTimestampFailsTheParse() {
        XCTAssertNil(Summarize.timestamps(in: "A claim [00:99:99]"))
    }

    func testCitationStartIsWhatGetsChecked() {
        // The range ends past the segment, in a pause. Only the start must land inside.
        let segments = [TranscriptSegment(start: 90, end: 100, text: "spoken words")]
        XCTAssertEqual(Summarize.timestamps(in: "[00:01:33-00:02:10]"), [93])
        XCTAssertTrue(Summarize.validProvenance(in: "A claim [00:01:33-00:02:10]", segments: segments))
    }
}
