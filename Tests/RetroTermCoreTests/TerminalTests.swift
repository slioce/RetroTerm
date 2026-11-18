import XCTest
@testable import RetroTermCore

final class TerminalTests: XCTestCase {
    func row(_ t: Terminal, _ y: Int) -> String { t.lines[y].text() }

    func testPrintAndWrap() {
        let t = Terminal(cols: 5, rows: 3)
        t.feed("abcdefg")
        XCTAssertEqual(row(t, 0), "abcde")
        XCTAssertEqual(row(t, 1), "fg")
        XCTAssertTrue(t.lines[0].wrapped)
        XCTAssertEqual(t.cursorX, 2)
        XCTAssertEqual(t.cursorY, 1)
    }

    func testScrollbackAndClear() {
        let t = Terminal(cols: 10, rows: 2)
        t.feed("one\r\ntwo\r\nthree\r\n")
        XCTAssertEqual(t.scrollback.count, 2)
        XCTAssertEqual(t.scrollback[0].text(), "one")
        XCTAssertEqual(row(t, 0), "three")
        t.feed("\u{1b}[2J")
        XCTAssertEqual(row(t, 0), "")
    }

    func testCursorMovementAndErase() {
        let t = Terminal(cols: 10, rows: 4)
        t.feed("hello world")
        t.feed("\u{1b}[2;3H")
        XCTAssertEqual(t.cursorY, 1); XCTAssertEqual(t.cursorX, 2)
        t.feed("\u{1b}[1;1H\u{1b}[K")
        XCTAssertEqual(row(t, 0), "")
        XCTAssertEqual(row(t, 1), "d")
    }

    func testSGRAndColors() {
        let t = Terminal(cols: 10, rows: 1)
        t.feed("\u{1b}[1;31mA\u{1b}[0m\u{1b}[38;5;200mB\u{1b}[38:2:1:2:3mC\u{1b}[48;2;9;8;7mD")
        XCTAssertTrue(t.lines[0].cells[0].style.attrs.contains(.bold))
        XCTAssertEqual(t.lines[0].cells[0].style.fg, .indexed(1))
        XCTAssertEqual(t.lines[0].cells[1].style.fg, .indexed(200))
        XCTAssertEqual(t.lines[0].cells[2].style.fg, .rgb(1, 2, 3))
        XCTAssertEqual(t.lines[0].cells[3].style.bg, .rgb(9, 8, 7))
    }

    func testScrollRegion() {
        let t = Terminal(cols: 5, rows: 4)
        t.feed("1\r\n2\r\n3\r\n4")
        t.feed("\u{1b}[2;3r\u{1b}[3;1H\n")
        XCTAssertEqual(row(t, 0), "1")
        XCTAssertEqual(row(t, 1), "3")
        XCTAssertEqual(row(t, 2), "")
        XCTAssertEqual(row(t, 3), "4")
    }

    func testAltScreen() {
        let t = Terminal(cols: 5, rows: 2)
        t.feed("main")
        t.feed("\u{1b}[?1049h")
        XCTAssertEqual(row(t, 0), "")
        t.feed("alt")
        t.feed("\u{1b}[?1049l")
        XCTAssertEqual(row(t, 0), "main")
        XCTAssertEqual(t.cursorX, 4)
    }

    func testWideChars() {
        let t = Terminal(cols: 4, rows: 2)
        t.feed("日本語")
        XCTAssertEqual(row(t, 0), "日本")
        XCTAssertEqual(row(t, 1), "語")
        XCTAssertTrue(t.lines[0].cells[1].isWideSpacer)
    }

    func testResponses() {
        let t = Terminal(cols: 10, rows: 5)
        var out: [UInt8] = []
        t.output = { out += $0 }
        t.feed("\u{1b}[3;4H\u{1b}[6n")
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "\u{1b}[3;4R")
    }

    func testResizePreservesContent() {
        let t = Terminal(cols: 10, rows: 3)
        t.feed("a\r\nb\r\nc\r\nd")
        t.resize(cols: 10, rows: 2)
        XCTAssertEqual(row(t, 0), "c")
        XCTAssertEqual(row(t, 1), "d")
        XCTAssertEqual(t.cursorY, 1)
        t.resize(cols: 10, rows: 4)
        XCTAssertEqual(row(t, 0), "a")
        XCTAssertEqual(row(t, 3), "d")
    }

    func testInsertDeleteChars() {
        let t = Terminal(cols: 6, rows: 1)
        t.feed("abcdef\u{1b}[1;2H\u{1b}[2P")
        XCTAssertEqual(row(t, 0), "adef")
        t.feed("\u{1b}[2@")
        XCTAssertEqual(row(t, 0), "a  def")
    }

    func testKeyEncoder() {
        var o = KeyEncoder.Options()
        XCTAssertEqual(KeyEncoder.encode(keyCode: KeyEncoder.Code.up, characters: "", charactersIgnoringModifiers: "", modifiers: [], options: o), Array("\u{1b}[A".utf8))
        o.applicationCursorKeys = true
        XCTAssertEqual(KeyEncoder.encode(keyCode: KeyEncoder.Code.up, characters: "", charactersIgnoringModifiers: "", modifiers: [], options: o), Array("\u{1b}OA".utf8))
        XCTAssertEqual(KeyEncoder.encode(keyCode: 0, characters: "\u{3}", charactersIgnoringModifiers: "c", modifiers: [.control], options: o), [3])
        XCTAssertEqual(KeyEncoder.encode(keyCode: 0, characters: "ß", charactersIgnoringModifiers: "s", modifiers: [.option], options: o), [0x1b, 0x73])
    }

    func testUTF8SplitAcrossFeeds() {
        let t = Terminal(cols: 5, rows: 1)
        let bytes = Array("é".utf8)
        t.feed([bytes[0]])
        t.feed([bytes[1]])
        XCTAssertEqual(row(t, 0), "é")
    }
}
