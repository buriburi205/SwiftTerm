#if os(iOS)
import Testing
import UIKit
@testable import SwiftTerm

@Suite("로컬 선택 모드", .serialized)
@MainActor
struct IOSSelectionModeTests {
    // 실제 셀 좌표 변환으로 부분 선택하고 원격 마우스 모드와 무관하게 입력을 차단한다.
    @Test("첫 드래그로 한글 부분 선택", arguments: ["", "\u{1b}[?1000h\u{1b}[?1006h", "\u{1b}[?1049h"])
    func selection(modes: String) async throws {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        view.feed(text: modes + "앞 한글 뒤")
        view.isSelectingText = true
        #expect(view.panSelectionGesture != nil)
        #expect(view.panGestureRecognizer.minimumNumberOfTouches == 2)
        #expect(!view.forwardTap(at: CGPoint(x: 8, y: 8)))
        let cell = view.cellDimension
        view.beginLocalSelection(at: CGPoint(x: 3.1 * cell.width, y: 0.5 * cell.height))
        view.extendLocalSelection(to: CGPoint(x: 7.1 * cell.width, y: 0.5 * cell.height))
        #expect(view.getSelection() == "한글")
        let clipboard = UIPasteboard.general.string
        defer { UIPasteboard.general.string = clipboard }
        view.copy(nil)
        #expect(UIPasteboard.general.string == "한글")
        #expect(view.getSelection() == nil)
        #expect(view.panSelectionGesture != nil)
        view.beginLocalSelection(at: CGPoint(x: 0.1 * cell.width, y: 0.5 * cell.height))
        view.extendLocalSelection(to: CGPoint(x: 2.1 * cell.width, y: 0.5 * cell.height))
        #expect(view.getSelection() == "앞")
        view.isSelectingText = false
        #expect(view.panSelectionGesture == nil)
        #expect(view.getSelection() == nil)
        #expect(view.allowMouseReporting)
    }

    // 선택 종료 후 마우스 추적 여부에 맞는 기존 스크롤 제스처로 복귀한다.
    @Test("원격 보고 설정 보존", arguments: [true, false])
    func restoration(reports: Bool) async throws {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        view.allowMouseReporting = reports
        view.isSelectingText = true
        view.isSelectingText = false
        #expect(view.allowMouseReporting == reports)
        #expect(view.panGestureRecognizer.minimumNumberOfTouches == 1)
    }
}
#endif
