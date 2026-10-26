import Testing
@testable import SwiftTerm
#if os(macOS)
import AppKit
#endif

final class ClearScreenTests: TerminalDelegate {
    var replies: [UInt8] = []
    func send(source: Terminal, data: ArraySlice<UInt8>) { replies += data }

    private func makeTerminal(cols: Int = 12, rows: Int = 4) -> Terminal {
        Terminal(delegate: self, options: TerminalOptions(cols: cols, rows: rows, scrollback: 20))
    }

    private func clear(_ terminal: Terminal) -> Bool {
        terminal.terminalLock.withLock { terminal.clearScreenPreservingCurrentLine() }
    }

    @Test func preservesCellsCursorAndModes() {
        let terminal = makeTerminal()
        terminal.feed(text: String(repeating: "old\r\n", count: 40))
        terminal.feed(text: "\u{1b}[?2004h\u{1b}[?1h\u{1b}[31m$ 한글\u{1b}[2D")
        let before = terminal.contentSnapshot(region: .history(maximumScrollbackRows: 0))
        let current = before.rows[before.cursorRow - before.liveTopRow]
        #expect(clear(terminal))
        let after = terminal.contentSnapshot(region: .history(maximumScrollbackRows: 100))
        #expect(after.rows[0].cells == current.cells)
        #expect(after.rows.dropFirst().allSatisfy { $0.text.trimmingCharacters(in: .whitespaces).isEmpty })
        #expect(after.cursorRow == after.liveTopRow)
        #expect(after.cursorColumn == before.cursorColumn)
        #expect(terminal.buffer.yBase == 0)
        #expect(after.inputState == before.inputState)
        #expect(replies.isEmpty)
        terminal.feed(text: "X")
        #expect(terminal.getText(col: before.cursorColumn, row: 0) == "X")
    }

    @Test func keepsWrappedLineWhenCursorIsInTheMiddle() {
        let terminal = makeTerminal(cols: 5)
        terminal.feed(text: "old\r\nabcdefghijk\u{1b}[1A\u{1b}[3G")
        #expect(clear(terminal))
        let snapshot = terminal.contentSnapshot(region: .history(maximumScrollbackRows: 100))
        #expect(snapshot.rows.map(\.text).prefix(3) == ["abcde", "fghij", "k"])
        #expect(snapshot.rows.prefix(3).map(\.isWrapped) == [false, true, true])
        #expect(snapshot.cursorRow - snapshot.liveTopRow == 1)
        #expect(snapshot.cursorColumn == 2)
        terminal.resize(cols: 10, rows: 4)
        #expect(String(decoding: terminal.getBufferAsData(), as: UTF8.self).replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: " ", with: "") == "abcdefghijk")
    }

    @Test func preservesLogicalLineLongerThanScreenAndPendingWrap() {
        let terminal = makeTerminal(cols: 5, rows: 2)
        terminal.feed(text: "old\r\nabcdefghijklmnopqrst")
        #expect(clear(terminal))
        #expect(String(decoding: terminal.getBufferAsData(), as: UTF8.self) == "abcde\nfghij\nklmno\npqrst\n")
        #expect(terminal.buffer.x == 5)
        terminal.feed(text: "u")
        #expect(String(decoding: terminal.getBufferAsData(), as: UTF8.self).hasSuffix("u\n"))
        #expect(clear(terminal))
        #expect(terminal.buffer.y < terminal.rows)
    }

    @Test func alternateScreenIsUnchangedIncludingNormalHistory() {
        let terminal = makeTerminal()
        terminal.feed(text: "old\r\nprompt\u{1b}[?1049hALT")
        let normal = terminal.getBufferAsData(kind: .normal)
        let alt = terminal.contentSnapshot(region: .history(maximumScrollbackRows: 100))
        #expect(!clear(terminal))
        #expect(terminal.contentSnapshot(region: .history(maximumScrollbackRows: 100)) == alt)
        #expect(terminal.getBufferAsData(kind: .normal) == normal)
        #expect(replies.isEmpty)
    }

    @Test func doesNotDisturbAnIncompleteParserSequence() {
        let terminal = makeTerminal()
        terminal.feed(text: "old\r\nprompt\u{1b}[3")
        #expect(clear(terminal))
        terminal.feed(text: "1mX")
        #expect(terminal.getText(col: 6, row: 0) == "X")
        #expect(!String(decoding: terminal.getBufferAsData(), as: UTF8.self).contains("1m"))
        #expect(replies.isEmpty)
    }

    @Test func savedCursorFollowsTheRetainedWrappedRow() {
        let terminal = makeTerminal(cols: 5)
        terminal.feed(text: String(repeating: "old\r\n", count: 40) + "abcdefg\u{1b}7")
        #expect(clear(terminal))
        terminal.feed(text: "\u{1b}[H\u{1b}8X")
        #expect(terminal.buffer.y == 1)
        #expect(terminal.getText(col: 2, row: 1) == "X")
    }

    @Test func repeatedClearsLeaveNoOldRowsAfterResizeAndOutput() {
        let terminal = makeTerminal()
        for _ in 0..<5 {
            terminal.feed(text: String(repeating: "discard\r\n", count: 40) + "$ ")
            #expect(clear(terminal))
            terminal.resize(cols: 10, rows: 6)
            terminal.feed(text: "next\r\n")
            #expect(!String(decoding: terminal.getBufferAsData(), as: UTF8.self).contains("discard"))
        }
    }

#if os(macOS)
    @Test @MainActor func viewClearsSelectionAndSearchCache() {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        view.feed(text: "old match\r\nprompt")
        #expect(view.findNext("match"))
        #expect(view.clearScreenPreservingCurrentLine())
        #expect(view.getSelection() == nil)
        #expect(view.searchMatchSummary("match").total == 0)
        #expect(view.searchMatchSummary("prompt").total == 1)
    }
#endif
}
