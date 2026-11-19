import XCTest
@testable import RetroBasic

/// Drives a machine synchronously: submits lines, pumps `step`, answers INPUT from `inputs`.
final class ScriptedHost {
    let machine: BasicMachine
    var out = ""
    var inputs: [String] = []

    init(columns: Int = 40) {
        machine = BasicMachine(random: { 0.5 })
        machine.columns = columns
        machine.output = { [unowned self] in self.out += $0 }
        machine.powerOn()
        out = ""
    }

    func enter(_ lines: String...) {
        for l in lines { machine.submitLine(l); pump() }
    }

    /// Submits a direct-mode line and returns everything printed, READY included.
    @discardableResult
    func command(_ s: String) -> String {
        out = ""
        machine.submitLine(s)
        pump()
        return out
    }

    /// Like `command` with the trailing "\nREADY.\n" removed.
    func line(_ s: String) -> String {
        let o = command(s)
        return o.hasSuffix("\nREADY.\n") ? String(o.dropLast(8)) : o
    }

    @discardableResult
    func pump(max: Int = 100_000) -> StepResult {
        var n = 0
        while n < max {
            n += 1
            switch machine.step() {
            case .running:
                continue
            case .awaitingLine:
                guard !inputs.isEmpty else { return .awaitingLine }
                machine.supplyLine(inputs.removeFirst())
            case let r:
                return r
            }
        }
        return machine.state
    }
}

final class BasicMachineTests: XCTestCase {
    func testBannerOnPowerOn() {
        let m = BasicMachine()
        var out = ""
        m.output = { out += $0 }
        m.powerOn()
        XCTAssertEqual(out, "\u{93}\n    **** RETROTERM BASIC V2 ****\n\n 64K RAM SYSTEM  38911 BASIC BYTES FREE\n\nREADY.\n")
        XCTAssertEqual(m.state, .ready)
    }

    func testImmediatePrint() {
        XCTAssertEqual(ScriptedHost().command("PRINT 1+2*3"), " 7 \n\nREADY.\n")
    }

    func testPrintSeparators() {
        let h = ScriptedHost()
        XCTAssertEqual(h.line("PRINT 1;2;3"), " 1  2  3 \n")
        XCTAssertEqual(h.line("PRINT \"A\",\"B\""), "A         B\n")
        XCTAssertEqual(h.line("PRINT \"A\";:PRINT \"B\""), "AB\n")
        XCTAssertEqual(h.line("PRINT \"A\";"), "A")
        XCTAssertEqual(h.line("?\"Q\""), "Q\n")
    }

    func testNumberFormatting() {
        XCTAssertEqual(ScriptedHost().line("PRINT 1/4;-1;10/4;1/3"), " .25 -1  2.5  .333333333 \n")
    }

    func testStringFunctions() {
        let h = ScriptedHost()
        XCTAssertEqual(h.line("PRINT LEFT$(\"HELLO\",2);RIGHT$(\"HELLO\",2);MID$(\"HELLO\",2,3);LEN(\"ABC\");CHR$(65);ASC(\"B\");VAL(\"12.5\");STR$(7)"),
                       "HELOELL 3 A 66  12.5  7\n")
        XCTAssertEqual(h.line("PRINT MID$(\"HELLO\",3);LEFT$(\"AB\",5)"), "LLOAB\n")
    }

    func testTwoCharacterVariableNames() {
        let h = ScriptedHost()
        XCTAssertEqual(h.line("ABCDE=1:ABXYZ=2:PRINT ABCDE"), " 2 \n")
        XCTAssertEqual(h.line("A$=\"X\":A=1.5:PRINT A;A$"), " 1.5 X\n")
    }

    func testPrecedenceAndLogic() {
        XCTAssertEqual(ScriptedHost().line("PRINT -2^2;1=1;1<2 AND 2>1;NOT 0;5 OR 2;7 AND 12;2<>2"), "-4 -1 -1 -1  7  4  0 \n")
    }

    func testStringCompareAndConcat() {
        XCTAssertEqual(ScriptedHost().line("PRINT \"ABC\"<\"ABD\";\"B\"+\"C\""), "-1 BC\n")
    }

    func testTypeMismatch() {
        let h = ScriptedHost()
        XCTAssertEqual(h.command("A$=1"), "\n?TYPE MISMATCH  ERROR\nREADY.\n")
        XCTAssertEqual(h.command("PRINT \"A\"+1"), "\n?TYPE MISMATCH  ERROR\nREADY.\n")
    }

    func testDivisionByZero() {
        XCTAssertEqual(ScriptedHost().command("PRINT 1/0"), "\n?DIVISION BY ZERO  ERROR\nREADY.\n")
    }

    func testIllegalQuantity() {
        let h = ScriptedHost()
        for s in ["PRINT CHR$(300)", "PRINT SQR(-1)", "PRINT 40000 AND 1"] {
            XCTAssertEqual(h.command(s), "\n?ILLEGAL QUANTITY  ERROR\nREADY.\n", s)
        }
    }

    func testForNext() {
        let h = ScriptedHost()
        h.enter("10 FOR I=1 TO 3:PRINT I;:NEXT:PRINT")
        XCTAssertEqual(h.command("RUN"), " 1  2  3 \n\nREADY.\n")
    }

    func testForRunsAtLeastOnceAndNegativeStep() {
        let h = ScriptedHost()
        h.enter("10 FOR I=5 TO 1:PRINT I:NEXT")
        XCTAssertEqual(h.command("RUN"), " 5 \n\nREADY.\n")
        h.enter("10 FOR I=10 TO 1 STEP -3:PRINT I;:NEXT")
        XCTAssertEqual(h.command("RUN"), " 10  7  4  1 \nREADY.\n")
    }

    func testNextWithVariableList() {
        let h = ScriptedHost()
        h.enter("10 FOR I=1 TO 2:FOR J=1 TO 2:PRINT I*10+J;:NEXT J,I")
        XCTAssertEqual(h.command("RUN"), " 11  12  21  22 \nREADY.\n")
    }

    func testNextWithoutFor() {
        XCTAssertEqual(ScriptedHost().command("NEXT"), "\n?NEXT WITHOUT FOR  ERROR\nREADY.\n")
    }

    func testGosubReturn() {
        let h = ScriptedHost()
        h.enter("10 GOSUB 100:PRINT \"B\":END", "100 PRINT \"A\":RETURN")
        XCTAssertEqual(h.command("RUN"), "A\nB\n\nREADY.\n")
        XCTAssertEqual(h.command("RETURN"), "\n?RETURN WITHOUT GOSUB  ERROR\nREADY.\n")
    }

    func testIfThenForms() {
        let h = ScriptedHost()
        h.enter("10 A=1:IF A=1 THEN 40",
                "20 PRINT \"NO\"",
                "30 END",
                "40 IF A THEN PRINT \"YES\":PRINT \"TOO\"",
                "50 IF A=0 GOTO 20",
                "60 IF A<>0 THEN PRINT \"DONE\"")
        XCTAssertEqual(h.command("RUN"), "YES\nTOO\nDONE\n\nREADY.\n")
    }

    func testDimArraysBadSubscriptRedim() {
        let h = ScriptedHost()
        h.enter("10 DIM A(2,2):A(1,2)=5:PRINT A(1,2);A(0,0)",
                "20 B(3)=7:PRINT B(3)",
                "30 PRINT B(11)")
        XCTAssertEqual(h.command("RUN"), " 5  0 \n 7 \n\n?BAD SUBSCRIPT  ERROR IN 30\nREADY.\n")
        XCTAssertEqual(h.command("DIM C(2):DIM C(3)"), "\n?REDIM'D ARRAY  ERROR\nREADY.\n")
    }

    func testUndefdStatement() {
        let h = ScriptedHost()
        XCTAssertEqual(h.command("GOTO 500"), "\n?UNDEF'D STATEMENT  ERROR\nREADY.\n")
        h.enter("10 GOSUB 999")
        XCTAssertEqual(h.command("RUN"), "\n?UNDEF'D STATEMENT  ERROR IN 10\nREADY.\n")
    }

    func testSyntaxErrorReportsLine() {
        let h = ScriptedHost()
        h.enter("10 PRINT \"A\"", "20 PRUNT \"B\"")
        XCTAssertEqual(h.command("RUN"), "A\n\n?SYNTAX  ERROR IN 20\nREADY.\n")
    }

    func testInputPromptAndRedo() {
        let h = ScriptedHost()
        h.enter("10 INPUT \"AGE\";A:PRINT A*2", "20 INPUT N$:PRINT \"HI \";N$")
        h.out = ""
        h.machine.submitLine("RUN")
        XCTAssertEqual(h.pump(), .awaitingLine)
        XCTAssertEqual(h.out, "AGE? ")
        h.inputs = ["ABC", "21", "BOB"]
        XCTAssertEqual(h.pump(), .ready)
        XCTAssertEqual(h.out, "AGE? ?REDO FROM START\n?  42 \n? HI BOB\n\nREADY.\n")
    }

    func testInputEmptyAnswerLeavesVariable() {
        let h = ScriptedHost()
        h.enter("10 A=5:INPUT A:PRINT A")
        h.inputs = [""]
        XCTAssertEqual(h.command("RUN"), "?  5 \n\nREADY.\n")
    }

    func testInputIsIllegalDirect() {
        XCTAssertEqual(ScriptedHost().command("INPUT A"), "\n?ILLEGAL DIRECT  ERROR\nREADY.\n")
    }

    func testBreak() {
        let h = ScriptedHost()
        h.enter("10 PRINT \"A\"", "20 GOTO 20")
        h.out = ""
        h.machine.submitLine("RUN")
        XCTAssertEqual(h.machine.step(budget: 100), .running)
        h.machine.interrupt()
        XCTAssertEqual(h.machine.step(), .ready)
        XCTAssertEqual(h.out, "A\n\nBREAK IN 20\nREADY.\n")
    }

    func testStopBreaks() {
        let h = ScriptedHost()
        h.enter("10 PRINT \"A\":STOP:PRINT \"B\"")
        XCTAssertEqual(h.command("RUN"), "A\n\nBREAK IN 10\nREADY.\n")
    }

    func testListAndRanges() {
        let h = ScriptedHost()
        h.enter("10 print \"hi\"", "20 ?a;b", "30 for i=1 to 3:next", "5 rem   spaced out")
        XCTAssertEqual(h.command("LIST"), "5 REM   SPACED OUT\n10 PRINT \"hi\"\n20 ?A;B\n30 FOR I=1 TO 3:NEXT\n\nREADY.\n")
        XCTAssertEqual(h.command("LIST 10-20"), "10 PRINT \"hi\"\n20 ?A;B\n\nREADY.\n")
        XCTAssertEqual(h.command("LIST -10"), "5 REM   SPACED OUT\n10 PRINT \"hi\"\n\nREADY.\n")
        XCTAssertEqual(h.command("LIST 20-"), "20 ?A;B\n30 FOR I=1 TO 3:NEXT\n\nREADY.\n")
        XCTAssertEqual(h.command("LIST 20"), "20 ?A;B\n\nREADY.\n")
    }

    func testLineReplaceDeleteNew() {
        let h = ScriptedHost()
        h.enter("10 PRINT \"A\"", "20 PRINT \"B\"", "10 PRINT \"C\"", "20")
        XCTAssertEqual(h.command("LIST"), "10 PRINT \"C\"\n\nREADY.\n")
        XCTAssertEqual(h.command("64000 PRINT"), "\n?SYNTAX  ERROR\nREADY.\n")
        XCTAssertEqual(h.command("NEW"), "\nREADY.\n")
        XCTAssertEqual(h.command("LIST"), "\nREADY.\n")
    }

    func testRunResetsVariables() {
        let h = ScriptedHost()
        h.enter("10 PRINT A", "A=5")
        XCTAssertEqual(h.command("RUN"), " 0 \n\nREADY.\n")
    }

    func testSysAndExit() {
        let h = ScriptedHost()
        XCTAssertEqual(h.command("SYS 49152"), "\nREADY.\n")
        XCTAssertEqual(h.command("SYS 64738"), "")
        XCTAssertEqual(h.machine.state, .exit)
        let h2 = ScriptedHost()
        XCTAssertEqual(h2.command("EXIT"), "")
        XCTAssertEqual(h2.machine.state, .exit)
    }

    func testDeviceNotPresent() {
        let h = ScriptedHost()
        for s in ["LOAD \"X\",8", "SAVE \"X\"", "VERIFY \"X\"", "OPEN 1,8,15"] {
            XCTAssertEqual(h.command(s), "\n?DEVICE NOT PRESENT  ERROR\nREADY.\n", s)
        }
    }

    func testRndUsesHostRandom() {
        XCTAssertEqual(ScriptedHost().line("PRINT RND(1)"), " .5 \n")
    }

    func testMathFunctions() {
        XCTAssertEqual(ScriptedHost().line("PRINT INT(-2.5);ABS(-3);SGN(-7);SQR(16);INT(EXP(0));SIN(0)"), "-3  3 -1  4  1  0 \n")
    }

    func testGoToWithSpace() {
        let h = ScriptedHost()
        h.enter("10 GO TO 30", "20 PRINT \"NO\"", "30 PRINT \"YES\"")
        XCTAssertEqual(h.command("RUN"), "YES\n\nREADY.\n")
    }

    func testSpacesAndColons() {
        let h = ScriptedHost()
        h.enter("10  PRINT   \"A\"  :  PRINT  \"B\"")
        XCTAssertEqual(h.command("RUN"), "A\nB\n\nREADY.\n")
    }

    func testCommaZoneWrapsNearRightEdge() {
        let h = ScriptedHost(columns: 20)
        XCTAssertEqual(h.line("PRINT 1,2,3"), " 1         2 \n 3 \n")
    }
}
