import XCTest
@testable import MacBayTUI

final class KeyParserTests: XCTestCase {

    private let escape: UInt8 = 27

    func testLoneEscapeStaysBufferedUntilSequenceIsRuledOut() {
        XCTAssertNil(Key.parsePrefix(bytes: [escape]), "A lone ESC may still grow into a sequence")
        XCTAssertNil(Key.parsePrefix(bytes: [escape, UInt8(ascii: "[")]), "A truncated CSI sequence is incomplete")
        XCTAssertEqual(Key.parsePrefix(bytes: [escape, escape])?.key, .escape)
    }

    func testSplitArrowSequenceParsesOnceComplete() {
        let bytes: [UInt8] = [escape, UInt8(ascii: "["), UInt8(ascii: "B")]
        guard let parsed = Key.parsePrefix(bytes: bytes) else {
            return XCTFail("Expected a complete down-arrow sequence")
        }
        XCTAssertEqual(parsed.key, .down)
        XCTAssertEqual(parsed.consumed, 3)
    }

    func testModifiedArrowSequenceIsConsumedWhole() {
        let bytes: [UInt8] = [escape, UInt8(ascii: "["), UInt8(ascii: "1"), UInt8(ascii: ";"), UInt8(ascii: "5"), UInt8(ascii: "A")]
        guard let parsed = Key.parsePrefix(bytes: bytes) else {
            return XCTFail("Expected a complete modified up-arrow sequence")
        }
        XCTAssertEqual(parsed.key, .up)
        XCTAssertEqual(parsed.consumed, 6)
    }

    func testKeyBurstIsParsedOneKeyAtATime() {
        var bytes: [UInt8] = [
            UInt8(ascii: "j"), UInt8(ascii: "k"), UInt8(ascii: "q"),
            escape, UInt8(ascii: "["), UInt8(ascii: "C")
        ]
        var keys: [Key] = []
        while let parsed = Key.parsePrefix(bytes: bytes) {
            keys.append(parsed.key)
            bytes.removeFirst(parsed.consumed)
        }

        XCTAssertEqual(keys, [.char("j"), .char("k"), .char("q"), .right])
        XCTAssertTrue(bytes.isEmpty)
    }

    func testMultiByteCharacterWaitsForCompleteSequence() {
        let bytes = Array("한".utf8)
        XCTAssertEqual(bytes.count, 3)
        XCTAssertNil(Key.parsePrefix(bytes: [bytes[0]]))
        XCTAssertNil(Key.parsePrefix(bytes: Array(bytes[0..<2])))
        XCTAssertEqual(Key.parsePrefix(bytes: bytes)?.key, .char("한"))
    }

    func testControlKeysParseDirectly() {
        XCTAssertEqual(Key.parsePrefix(bytes: [3])?.key, .ctrlC)
        XCTAssertEqual(Key.parsePrefix(bytes: [13])?.key, .enter)
        XCTAssertEqual(Key.parsePrefix(bytes: [127])?.key, .backspace)
        XCTAssertEqual(Key.parsePrefix(bytes: [9])?.key, .tab)
    }
}
