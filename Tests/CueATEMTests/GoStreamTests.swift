import XCTest
@testable import CueATEM

final class GoStreamTests: XCTestCase {
    func testCRCMatchesModbusCheckValue() {
        XCTAssertEqual(GoStreamCodec.crc16Modbus(Array("123456789".utf8)), 0x4B37)
    }

    func testEncodeMatchesReferenceFrame() {
        // Same bytes the Companion module's PackData produces for pgmIndex = 9.
        let frame = GoStreamCodec.encode(GoStreamCommands.setProgram(9))
        XCTAssertEqual(frame, [0xEB, 0xA6, 0x00, 0x2C, 0x00,
                               0x7B, 0x22, 0x69, 0x64, 0x22, 0x3A, 0x22, 0x70, 0x67, 0x6D, 0x49, 0x6E, 0x64, 0x65, 0x78, 0x22,
                               0x2C, 0x22, 0x74, 0x79, 0x70, 0x65, 0x22, 0x3A, 0x22, 0x73, 0x65, 0x74, 0x22,
                               0x2C, 0x22, 0x76, 0x61, 0x6C, 0x75, 0x65, 0x22, 0x3A, 0x5B, 0x39, 0x5D, 0x7D,
                               0xB0, 0x04])
    }

    func testRoundTripAcrossSplitReads() {
        let frames = GoStreamCodec.encodeAll([GoStreamCommands.setPreview(3), GoStreamCommands.cut()])
        var decoder = GoStreamDecoder()
        var out: [GoStreamCommand] = []
        // Feed one byte at a time to exercise partial frames.
        for byte in frames { out += decoder.feed([byte]) }
        XCTAssertEqual(out, [GoStreamCommands.setPreview(3), GoStreamCommands.cut()])
    }

    func testBadCRCIsDropped() {
        var frame = GoStreamCodec.encode(GoStreamCommands.cut())
        frame[frame.count - 1] ^= 0xFF
        var decoder = GoStreamDecoder()
        XCTAssertTrue(decoder.feed(frame).isEmpty)
    }
}

final class GoStreamBridgeTests: XCTestCase {
    func testWaitsForFirstProgramReply() {
        let s = ATEMState(goStream: GoStreamState())
        XCTAssertTrue(s.inputs.isEmpty)
        XCTAssertNil(s.program[0])
    }

    func testMapsProgramPreviewAndTally() {
        var g = GoStreamState()
        g.deviceModel = 0
        g.program = 2
        g.preview = 3
        g.inputs = [1, 2, 3, 4]
        g.transitionStyle = "Wipe"
        g.ftb = 1
        let s = ATEMState(goStream: g)
        XCTAssertEqual(s.product, "GoStream Deck")
        XCTAssertEqual(s.program[0], 2)
        XCTAssertEqual(s.preview[0], 3)
        XCTAssertEqual(s.style[0], 2)
        XCTAssertEqual(s.ftbBlack[0], true)
        XCTAssertEqual(s.tally[2], 1)
        XCTAssertEqual(s.tally[3], 2)
        XCTAssertEqual(s.inputs.count, 4)
        XCTAssertEqual(s.auxCount, 0)
        XCTAssertEqual(s.dskCount, 0)
    }

    func testStreamAndRecordFlags() {
        var g = GoStreamState()
        g.program = 1
        XCTAssertFalse(ATEMState(goStream: g).hasStreaming)
        g.streamStatus = [0: 1]
        g.recordStatus = 1
        let s = ATEMState(goStream: g)
        XCTAssertTrue(s.hasStreaming && s.streaming)
        XCTAssertTrue(s.hasRecording && s.recording)
    }

    func testSwitcherKindParsing() {
        XCTAssertEqual(SwitcherKind.parse("goStream"), .goStream)
        XCTAssertEqual(SwitcherKind.parse("GoStream"), .goStream)
        XCTAssertEqual(SwitcherKind.parse(""), .atem)
        XCTAssertEqual(SwitcherKind.parse("whatever"), .atem)
    }
}
