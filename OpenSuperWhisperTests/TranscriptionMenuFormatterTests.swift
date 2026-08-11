import XCTest
@testable import OpenSuperWhisper

final class TranscriptionMenuFormatterTests: XCTestCase {

    func testMenuTitle_shortText_isUnchanged() {
        XCTAssertEqual(
            TranscriptionMenuFormatter.menuTitle(for: "Fix the deploy", maxLength: 50),
            "Fix the deploy")
    }

    // NSMenuItem titles render newlines badly, so they must collapse away.
    func testMenuTitle_collapsesNewlinesAndRunsOfWhitespace() {
        XCTAssertEqual(
            TranscriptionMenuFormatter.menuTitle(for: "one\ntwo\t\tthree   four", maxLength: 50),
            "one two three four")
    }

    func testMenuTitle_trimsLeadingAndTrailingWhitespace() {
        XCTAssertEqual(
            TranscriptionMenuFormatter.menuTitle(for: "  \n padded \n ", maxLength: 50),
            "padded")
    }

    func testMenuTitle_exactlyMaxLength_isNotTruncated() {
        let text = String(repeating: "a", count: 20)
        XCTAssertEqual(TranscriptionMenuFormatter.menuTitle(for: text, maxLength: 20), text)
    }

    func testMenuTitle_longText_isTruncatedWithEllipsis() {
        let result = TranscriptionMenuFormatter.menuTitle(
            for: "The quick brown fox jumps over the lazy dog and keeps running",
            maxLength: 20)

        XCTAssertTrue(result.hasSuffix("…"), "truncated titles must signal truncation")
        XCTAssertLessThanOrEqual(result.count, 21, "body must fit maxLength, plus the ellipsis")
    }

    func testMenuTitle_truncatesOnWordBoundary() {
        let result = TranscriptionMenuFormatter.menuTitle(
            for: "The quick brown fox jumps",
            maxLength: 14)

        // "The quick brown" is 15 chars, so it must cut back to "The quick".
        XCTAssertEqual(result, "The quick…")
    }

    func testMenuTitle_singleWordLongerThanLimit_isHardCut() {
        let result = TranscriptionMenuFormatter.menuTitle(
            for: "Pneumonoultramicroscopicsilicovolcanoconiosis",
            maxLength: 10)

        XCTAssertEqual(result, "Pneumonoul…")
    }

    func testMenuTitle_emptyText_returnsEmpty() {
        XCTAssertEqual(TranscriptionMenuFormatter.menuTitle(for: "   \n ", maxLength: 50), "")
    }

    func testMenuTitle_nonPositiveMaxLength_returnsEmpty() {
        XCTAssertEqual(TranscriptionMenuFormatter.menuTitle(for: "anything", maxLength: 0), "")
    }
}
