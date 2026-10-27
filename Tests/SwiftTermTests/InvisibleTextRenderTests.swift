#if os(macOS)
import AppKit
import Testing
@testable import SwiftTerm

@MainActor
@Suite("SGR 8 렌더링")
struct InvisibleTextRenderTests {
    private func makeView() -> TerminalView {
        let view = TerminalView(frame: .zero, font: nil,
                                options: TerminalOptions(cols: 24, rows: 4, scrollback: 20))
        view.minimumContrastRatio = 21
        view.linkHighlightMode = .always
        view.linkColor = .yellow
        return view
    }

    private func frame(_ view: TerminalView) throws
        -> (TerminalSnapshot.Row, Int, SnapshotRenderContext)
    {
        let snapshot = TerminalSnapshot()
        view.withTerminal { terminal in
            _ = snapshot.refresh(terminal: terminal, viewState: FrameViewState(view: view),
                                 selection: SnapshotSelectionState(selection: view.selection),
                                 deferBidiTypesetting: false)
        }
        let row = try #require(snapshot.rows.first)
        return (row, snapshot.firstRow,
                SnapshotRenderContext(viewState: FrameViewState(view: view), snapshot: snapshot))
    }

    // 실제 Cocoa 렌더링 경계의 attributed string·색상 상호운용을 최소 범위에서 검사한다.
    private func attributes(at column: Int, in info: ViewLineInfo) throws
        -> [NSAttributedString.Key: Any]
    {
        let segment = try #require(info.segments.first {
            column >= $0.column && $0.utf16ToCellOrdinal.contains((column - $0.column) / $0.columnWidth)
        })
        let ordinal = (column - segment.column) / segment.columnWidth
        let index = try #require(segment.utf16ToCellOrdinal.firstIndex(of: ordinal))
        return segment.attributedString.attributes(at: index, effectiveRange: nil)
    }

    private func alpha(_ color: PlainColor) -> CGFloat {
        switch color {
        case .rgb: 1
        case .color(let color): color.alphaComponent
        }
    }

    // 선택·링크·최소 대비 보정 뒤에도 글리프와 장식을 숨기고 셀 배경·원문을 보존한다.
    @Test("숨김 문자는 선택과 링크 강조에서도 배경만 유지", arguments: [false, true])
    func attributed(_ selected: Bool) async throws {
        let view = makeView()
        view.feed(text: "\u{1b}[31;44;4;9;8m\u{1b}]8;;https://example.test\u{7}X"
                  + "\u{1b}]8;;\u{7}\u{1b}[28mY")
        if selected {
            view.withTerminal { _ in
                view.selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 1, row: 0))
            }
        }
        let (row, index, context) = try frame(view)
        let info = view.textBuilder.buildAttributedString(row: row, absoluteRow: index, context: context)
        let hidden = try attributes(at: 0, in: info)
        let visible = try attributes(at: 1, in: info)

        #expect((hidden[.foregroundColor] as? TTColor)?.alphaComponent == 0)
        #expect((hidden[SwiftTermShapeColorKey] as? TTColor)?.alphaComponent == 0)
        #expect(hidden[.underlineStyle] == nil)
        #expect(hidden[.strikethroughStyle] == nil)
        #expect(hidden[SwiftTermUnderlineStyleKey] == nil)
        #expect((hidden[.backgroundColor] as? TTColor) == (visible[.backgroundColor] as? TTColor))
        #expect((hidden[.selectionBackgroundColor] != nil) == selected)
        #expect((visible[.foregroundColor] as? TTColor)?.alphaComponent == 1)
        #expect(visible[.underlineStyle] != nil)
        #expect(visible[.strikethroughStyle] != nil)
        #expect(row.text(at: 0, cell: row.line.packedView(at: 0)) == "X")
        #expect(row.text(at: 1, cell: row.line.packedView(at: 1)) == "Y")
        if selected {
            #expect(view.withTerminal { _ in view.selection.getSelectedText() } == "X")
        }
    }

    // Metal의 ASCII fast path도 숨김을 선택·링크 색보다 나중에 적용하며 SGR 28을 복원한다.
    @Test("plain 행은 숨김과 장식을 제거하고 SGR 28을 복원", arguments: [false, true])
    func plain(_ selected: Bool) async throws {
        let view = makeView()
        view.feed(text: "\u{1b}[31;44;4;9;8m\u{1b}]8;;https://example.test\u{7}X"
                  + "\u{1b}]8;;\u{7}\u{1b}[28mY")
        if selected {
            view.withTerminal { _ in
                view.selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 1, row: 0))
            }
        }
        let (row, index, context) = try frame(view)
        let rendered = try #require(view.textBuilder.plainRow(row: row, absoluteRow: index, context: context))
        let hidden = try #require(rendered.runs.first { $0.start == 0 })
        let visible = try #require(rendered.runs.first { $0.start == 1 })

        #expect(Array(rendered.codes.prefix(2)) == [0x20, 0x59])
        #expect(alpha(hidden.style.foreground) == 0)
        #expect(alpha(hidden.style.shapeColor) == 0)
        #expect(hidden.style.underline == nil)
        #expect(hidden.style.strikethrough == nil)
        #expect(hidden.style.background.key == visible.style.background.key)
        #expect(hidden.style.explicitBackground)
        #expect((hidden.style.selectionBackground != nil) == selected)
        #expect(alpha(visible.style.foreground) == 1)
        #expect(visible.style.underline != nil)
        #expect(visible.style.strikethrough != nil)
        #expect(row.line.packedView(at: 0).code == 0x58)
    }

    // 렌더링용 공백으로 색상 이모지까지 숨기되 원본 grapheme과 뒤 문자의 셀 위치는 유지한다.
    @Test("다중 칸과 결합 문자의 원문과 셀 폭 보존", arguments: ["한", "e\u{301}", "😀", "م"])
    func grapheme(_ text: String) async throws {
        let view = makeView()
        view.feed(text: "\u{1b}[8m" + text + "\u{1b}[28mZ")
        let (row, index, context) = try frame(view)
        let cell = row.line.packedView(at: 0)
        let width = max(1, Int(cell.width))
        let info = view.textBuilder.buildAttributedString(row: row, absoluteRow: index, context: context)
        let hiddenColumn = row.bidiLayout?.logicalToVisualCol[0] ?? 0
        let visibleColumn = row.bidiLayout?.logicalToVisualCol[width] ?? width
        let first = try #require(info.segments.first {
            hiddenColumn >= $0.column && $0.utf16ToCellOrdinal.contains((hiddenColumn - $0.column) / $0.columnWidth)
        })
        let hidden = try attributes(at: hiddenColumn, in: info)
        let visible = try attributes(at: visibleColumn, in: info)

        #expect(row.text(at: 0, cell: cell) == text)
        #expect(row.text(at: width, cell: row.line.packedView(at: width)) == "Z")
        #expect(first.columnWidth == width)
        #expect(first.attributedString.string.first == " ")
        #expect((hidden[.foregroundColor] as? TTColor)?.alphaComponent == 0)
        #expect((visible[.foregroundColor] as? TTColor)?.alphaComponent == 1)
    }

    // 독립 도형 경로가 숨김 글자를 다시 만들지 않으며 일반 폰트 경로도 같은 정책을 쓴다.
    @Test("Powerline과 box·block 도형 숨김", arguments: [false, true])
    func shapes(_ custom: Bool) async throws {
        let view = makeView()
        view.customBlockGlyphs = custom
        view.feed(text: "\u{1b}[31;44;4;9;8m─█\u{e0b0}\u{1b}[28mZ")
        view.withTerminal { _ in
            view.selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 3, row: 0))
        }
        let (row, index, context) = try frame(view)
        let info = view.textBuilder.buildAttributedString(row: row, absoluteRow: index, context: context)

        #expect(info.powerlineGlyphs.isEmpty)
        #expect(info.boxDrawings.isEmpty)
        #expect(info.blockElements.isEmpty)
        let hiddenAttributes = try (0..<3).map { try attributes(at: $0, in: info) }
        #expect(hiddenAttributes.allSatisfy { ($0[.foregroundColor] as? TTColor)?.alphaComponent == 0 })
        #expect(hiddenAttributes.allSatisfy { $0[.underlineStyle] == nil && $0[.strikethroughStyle] == nil })
        #expect(hiddenAttributes.allSatisfy { $0[.selectionBackgroundColor] != nil })
    }

    // 텍스트로 지정하는 Kitty placeholder도 숨김 동안 표시 항목을 만들지 않고 해제 후 복원한다.
    @Test("숨김 placeholder는 이미지 배치를 생성하지 않음")
    func placeholder() async throws {
        let view = makeView()
        view.feed(text: "\u{1b}[38;2;0;0;1;8m\u{10eeee}\u{1b}[28m\u{10eeee}")
        let (row, index, context) = try frame(view)
        let info = view.textBuilder.buildAttributedString(row: row, absoluteRow: index, context: context)

        #expect(info.kittyPlaceholders.count == 1)
        #expect(info.kittyPlaceholders.first?.col == 1)
        #expect(row.text(at: 0, cell: row.line.packedView(at: 0)) == "\u{10eeee}")
    }

    // 숨김은 표시만 생략하며 다음 셀이 이어받는 이미지 좌표와 ID 메타데이터는 유지한다.
    @Test("숨김 placeholder 뒤의 SGR 28은 생략된 이미지 정보를 상속")
    func placeholderContinuation() async throws {
        let view = makeView()
        let hidden = "\u{10eeee}\u{030e}\u{0310}\u{0312}"
        view.feed(text: "\u{1b}[38;2;0;0;1;58;2;0;0;7;8m" + hidden
                  + "\u{1b}[28m\u{10eeee}")
        let (row, index, context) = try frame(view)
        let info = view.textBuilder.buildAttributedString(row: row, absoluteRow: index, context: context)
        let visible = try #require(info.kittyPlaceholders.first)

        #expect(info.kittyPlaceholders.count == 1)
        #expect(visible.col == 1)
        #expect(visible.placeholderRow == 2)
        #expect(visible.placeholderCol == 4)
        #expect(visible.msb == 4)
        #expect(visible.imageId == 0x04000001)
        #expect(visible.placementId == 7)
        #expect(row.text(at: 0, cell: row.line.packedView(at: 0)) == hidden)
    }
}
#endif
