import AppKit
import SwiftUI

@MainActor func renderTodoControls() throws {
    var pending = TodoItem(text: "检查待办的标题、时间与重要标记", priority: "high",
                           dueAt: Date(timeIntervalSince1970: 1790000000), number: 1)
    pending.tagIDs = []
    var completed = pending; completed.id = UUID(); completed.text = "已完成的任务可以删除"
    completed.completed = true; completed.number = 2
    var archived = pending; archived.id = UUID(); archived.text = "已归档的任务可以恢复或删除"
    archived.archivedAt = Date(); archived.number = 3
    let session = TodoEditSession(original: pending, epoch: LocalProfile.epoch)
    for dark in [false, true] {
        let content = VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 20) {
                controlPreviewCard("窄窗口 · 未完成", item: pending, width: 210, quick: true)
                controlPreviewCard("已完成", item: completed, width: 300, quick: false)
                controlPreviewCard("已归档", item: archived, width: 300, quick: false)
            }
            HStack(alignment: .top, spacing: 24) {
                TodoTitleEditor(session: session, close: {})
                    .background(TodoTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                TodoDateEditor(session: session, close: {})
                    .background(TodoTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            }
            Spacer(minLength: 0)
        }.padding(24).background(TodoTheme.canvas).environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: content)
        let rect = NSRect(x: 0, y: 0, width: 920, height: 500)
        let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host; host.frame = rect
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/todo-controls-\(dark ? "dark" : "light").png"))
        window.orderOut(nil)
    }
}

private func controlPreviewCard(_ title: String, item: TodoItem, width: CGFloat, quick: Bool) -> some View {
    VStack(alignment: .leading, spacing: 10) {
        Text(title).font(.headline)
        TodoRow(item: item, epoch: LocalProfile.epoch, showQuickActions: quick, edit: {}, editDate: {}, toggle: {})
    }.frame(width: width)
}
