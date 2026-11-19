import XCTest
import RetroTermCore
@testable import RetroBasic

final class BasicConsoleTests: XCTestCase {
    var terminal: Terminal!
    var console: BasicConsole!

    override func setUp() {
        terminal = Terminal(cols: 40, rows: 10)
        console = BasicConsole(machine: BasicMachine(random: { 0.5 }), screen: TerminalScreen(terminal: terminal, lock: nil))
        console.start()
    }

    private func row(_ y: Int) -> String { terminal.lines[y].text() }
    private func type(_ s: String) { console.handleInput(Array(s.utf8)) }
    private func enter(_ s: String) { type(s); console.handleInput([0x0D]) }
    private var screenRows: [String] { terminal.lines.map { $0.text() } }

    func testBannerFillsScreenAndCursorAfterReady() {
        XCTAssertEqual(row(1), "    **** RETROTERM BASIC V2 ****")
        XCTAssertEqual(row(3), " 64K RAM SYSTEM  38911 BASIC BYTES FREE")
        XCTAssertEqual(row(5), "READY.")
        XCTAssertEqual(terminal.cursorY, 6)
        XCTAssertEqual(terminal.cursorX, 0)
    }

    func testTypedCharactersEchoUppercase() {
        type("print 1")
        XCTAssertEqual(row(6), "PRINT 1")
        XCTAssertEqual(terminal.cursorX, 7)
    }

    func testReturnSubmitsRowAndPrintsResult() {
        enter("print 1")
        // The newline after READY. scrolled the 10-row screen by one.
        XCTAssertEqual(Array(screenRows[5...9]), ["PRINT 1", " 1", "", "READY.", ""])
        XCTAssertEqual(terminal.cursorY, 9)
    }

    func testEditListedLineInPlace() {
        enter("10 print \"a\"")
        console.handleInput(Array("\u{1b}[H\u{1b}[2J".utf8))   // not a key; clear via escape path is Shift+Home
        type("\u{1b}[1;2H")
        enter("list")
        XCTAssertEqual(row(0), "LIST")
        XCTAssertEqual(row(1), "10 PRINT \"A\"")
        // Cursor is on row 4 after READY; go up to the listed line, right 10 columns, overwrite the A.
        for _ in 0..<3 { type("\u{1b}[A") }
        for _ in 0..<10 { type("\u{1b}[C") }
        XCTAssertEqual(terminal.cursorY, 1)
        XCTAssertEqual(terminal.cursorX, 10)
        enter("b")
        XCTAssertEqual(row(1), "10 PRINT \"B\"")
        type("\u{1b}[1;2H")
        enter("list")
        XCTAssertEqual(row(1), "10 PRINT \"B\"")
    }

    func testInputStripsPrompt() {
        enter("10 input \"name\";n$:print \"hi \";n$")
        enter("run")
        XCTAssertEqual(row(8), "NAME?")
        XCTAssertEqual(terminal.cursorX, 6)
        enter("bob")
        let rows = screenRows
        guard let prompt = rows.firstIndex(of: "NAME? BOB") else { return XCTFail("\(rows)") }
        XCTAssertEqual(rows[prompt + 1], "HI BOB")
        XCTAssertEqual(rows[prompt + 2], "")
        XCTAssertEqual(rows[prompt + 3], "READY.")
    }

    func testCtrlCBreaksRunningProgram() {
        enter("10 goto 10")
        type("run")
        XCTAssertEqual(console.handleInput([0x0D]), .moreWork)
        XCTAssertEqual(console.drive(), .moreWork)
        XCTAssertEqual(console.handleInput([0x03]), .idle)
        XCTAssertTrue(screenRows.contains("BREAK IN 10"), "\(screenRows)")
        XCTAssertEqual(screenRows.last(where: { !$0.isEmpty }), "READY.")
        XCTAssertEqual(console.drive(), .idle)
    }

    func testBackspaceDeletesLeft() {
        type("abc")
        console.handleInput([0x7F])
        XCTAssertEqual(row(6), "AB")
        XCTAssertEqual(terminal.cursorX, 2)
        console.handleInput([0x7F]); console.handleInput([0x7F]); console.handleInput([0x7F])
        XCTAssertEqual(terminal.cursorX, 0)
    }

    func testArrowsBothEncodingsHomeAndLoneEscape() {
        type("\u{1b}OA")
        XCTAssertEqual(terminal.cursorY, 5)
        type("\u{1b}[A")
        XCTAssertEqual(terminal.cursorY, 4)
        type("\u{1b}[C\u{1b}[C")
        XCTAssertEqual(terminal.cursorX, 2)
        type("\u{1b}[1;5D")
        XCTAssertEqual(terminal.cursorX, 1)
        console.handleInput([0x1B])
        XCTAssertEqual((terminal.cursorX, terminal.cursorY).0, 1)
        type("\u{1b}[H")
        XCTAssertEqual(terminal.cursorY, 0)
        XCTAssertEqual(terminal.cursorX, 0)
    }

    func testSys64738Exits() {
        type("sys 64738")
        XCTAssertEqual(console.handleInput([0x0D]), .exited)
    }

    func testPetsciiToVT() {
        XCTAssertEqual(BasicConsole.vt(forPETSCII: "A\u{93}B\n"), "A\u{1b}[H\u{1b}[2JB\r\n")
    }

    func testPasteTypesLines() {
        console.paste("10 print 1\n20 print 2\r\nrun\n")
        let rows = screenRows
        XCTAssertEqual(rows.last(where: { !$0.isEmpty }), "READY.")
        XCTAssertTrue(rows.contains(" 1") && rows.contains(" 2"), "\(rows)")
    }

    func testIgnoresKeysWhileRunning() {
        enter("10 goto 10")
        enter("run")
        let before = screenRows
        type("abc\u{1b}[A")
        XCTAssertEqual(screenRows, before)
        console.handleInput([0x03])
    }
}
