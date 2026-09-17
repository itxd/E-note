import AppKit
import SwiftUI

@MainActor func runTodoTypingTests() {
    let host = NSHostingView(rootView: TodoListView())
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    func fields(_ view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { fields($0) }
    }
    guard let input = fields(host).first(where: { $0.placeholderString == "添加一个待办…" }) else {
        assertionFailure("missing task composer"); return
    }
    window.makeFirstResponder(input)
    guard let editor = input.currentEditor() as? NSTextView else {
        assertionFailure("missing text editor"); return
    }
    let before = NoteStore.shared.todos()
    let start = Date()
    for _ in 0..<40 {
        editor.insertText("输入测试", replacementRange: editor.selectedRange())
        RunLoop.main.run(until: Date().addingTimeInterval(0.001))
    }
    assert(input.stringValue == String(repeating: "输入测试", count: 40))
    assert(NoteStore.shared.todos() == before, "typing must not persist or recreate tasks")
    print("PASS: wide task list typed 160 characters without persisting; elapsed \(Date().timeIntervalSince(start))s")
    window.orderOut(nil)
}
