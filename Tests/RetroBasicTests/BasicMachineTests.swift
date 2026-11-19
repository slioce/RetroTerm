import XCTest
@testable import RetroBasic

final class BasicMachineTests: XCTestCase {
    func testBannerOnPowerOn() {
        let m = BasicMachine()
        var out = ""
        m.output = { out += $0 }
        m.powerOn()
        XCTAssertEqual(out, "\u{93}\n    **** RETROTERM BASIC V2 ****\n\n 64K RAM SYSTEM  38911 BASIC BYTES FREE\n\nREADY.\n")
        XCTAssertEqual(m.state, .ready)
    }
}
