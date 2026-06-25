import XCTest
@testable import OpenSuperWhisper

final class TextInserterTests: XCTestCase {

    /// Decode a list of UTF-16 chunks back into a single String.
    private func reconstruct(_ chunks: [[UniChar]]) -> String {
        chunks.map { String(utf16CodeUnits: $0, count: $0.count) }.joined()
    }

    func testEmptyStringProducesNoChunks() {
        XCTAssertEqual(TextInserter.chunks(of: "").count, 0)
    }

    func testShortStringIsOneChunk() {
        let chunks = TextInserter.chunks(of: "hello", maxUnits: 20)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(reconstruct(chunks), "hello")
    }

    func testReconstructionMatchesOriginal() {
        for text in ["hello world", "café crème", "line1\nline2\nline3", "a👍b🎉c"] {
            let chunks = TextInserter.chunks(of: text, maxUnits: 3)
            XCTAssertEqual(reconstruct(chunks), text, "round-trip failed for \(text)")
        }
    }

    func testNoChunkExceedsMaxForPlainText() {
        let chunks = TextInserter.chunks(of: String(repeating: "x", count: 50), maxUnits: 20)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 20 })
        XCTAssertEqual(chunks.count, 3) // 20 + 20 + 10
    }

    func testSurrogatePairIsNeverSplit() {
        // "a👍b": utf16 = [a, high, low, b]. With maxUnits 2 the boundary would
        // fall mid-emoji; the chunker must keep the pair together.
        let chunks = TextInserter.chunks(of: "a👍b", maxUnits: 2)
        XCTAssertEqual(reconstruct(chunks), "a👍b")
        for chunk in chunks {
            if let last = chunk.last {
                XCTAssertFalse((0xD800...0xDBFF).contains(last),
                               "chunk must not end on an unpaired high surrogate")
            }
        }
    }

    func testNewlineIsPreservedAsAUnit() {
        let chunks = TextInserter.chunks(of: "a\nb", maxUnits: 20)
        XCTAssertEqual(reconstruct(chunks), "a\nb")
    }
}
