import XCTest
@testable import CueVideo

final class FrameBoxTests: XCTestCase {
    func testDefaultsAreCentredOnTheMiddle() {
        let b = FrameBox(.waist, CueConfig())
        XCTAssertEqual(b.markX, 0.5, accuracy: 0.0001)
        XCTAssertEqual(b.deadX, ShotSize.waist.standard.deadX ?? 0, accuracy: 0.0001)
    }

    func testSetupFileOverridesWin() {
        var c = CueConfig()
        c.framing["waist"] = FramingRule(deadX: 0.2, markX: 0.3)
        let b = FrameBox(.waist, c)
        XCTAssertEqual(b.markX, 0.3, accuracy: 0.0001)
        XCTAssertEqual(b.deadX, 0.2, accuracy: 0.0001)
        XCTAssertEqual(b.eyeLine, ShotSize.waist.standard.eyeLine ?? 0, accuracy: 0.0001, "what isn't overridden stays standard")
    }

    func testClampKeepsTheBoxOnThePicture() {
        let b = FrameBox(markX: 1.4, eyeLine: -0.2, deadX: 0.9, deadY: 0).clamped
        XCTAssertEqual(b, FrameBox(markX: 0.9, eyeLine: 0.08, deadX: 0.3, deadY: 0.02))
    }

    func testFramingRuleRoundTripsMarkX() throws {
        var c = CueConfig()
        c.framing["full"] = FramingRule(markX: 0.7)
        let back = try JSONDecoder().decode(CueConfig.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back.framing["full"]?.markX, 0.7)
    }
}
