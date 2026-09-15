import AppKit
import SwiftUI

final class EditorSwitchState: ObservableObject {
    @Published var id: UUID
    init(id: UUID) { self.id = id }
}
struct EditorSwitchView: View {
    @ObservedObject var state: EditorSwitchState
    var body: some View { NoteEditor(noteID: state.id, deck: nil) }
}

@main
struct ENoteTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let store = NoteStore.shared
        if CommandLine.arguments.contains("cloud-merge") { runCloudMergeTests(); try runProfileIsolationTests(); return }
        if CommandLine.arguments.contains("todo-features") { try runTodoFeatureTests(); return }
        if CommandLine.arguments.contains("serve") {
            LocalAPIServer.shared.configure()
            if ProcessInfo.processInfo.environment["ENOTE_TEST_AUTO_SYNC"] == "1" { CloudSync.shared.start() }
            // 仅测试宿主读取 stdin；正式应用没有这些控制命令。
            DispatchQueue.global().async {
                while let command = readLine() {
                    DispatchQueue.main.async {
                        if command == "api-off" { AppSettings.shared.apiEnabled = false }
                        if command == "api-on" { AppSettings.shared.apiEnabled = true }
                        if command == "todo-off" { AppSettings.shared.todoListEnabled = false }
                        if command == "todo-on" { AppSettings.shared.todoListEnabled = true }
                    }
                }
            }
            RunLoop.main.run()
            return
        }
        if CommandLine.arguments.contains("preview-account") {
            let host = NSHostingView(rootView: AccountSettingsView().frame(width: 640, height: 460).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
            let rect = NSRect(x: 0, y: 0, width: 640, height: 460)
            let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = host; host.frame = rect
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/account-preview.png"))
            window.orderOut(nil)
            return
        }
        if CommandLine.arguments.contains("preview") {
            store.saveTodos([
                TodoItem(text: "完成 E note 接口联调", category: "工作", priority: "high", dueAt: Date().addingTimeInterval(-3600)),
                TodoItem(text: "读完设计系统这一章", category: "学习", dueAt: Date().addingTimeInterval(300)),
                TodoItem(text: "周末买花，给阳台添一点颜色", category: "生活", completed: true),
                TodoItem(text: "把下周的想法整理成三个行动项", category: "计划")
            ])
            OverdueWatcher.shared.refresh()
            for dark in [false, true] {
                let content = HStack(alignment: .top, spacing: 24) {
                    previewColumn("70% · 238 × 260", width: 238, height: 260)
                    previewColumn("100% · 340 × 340", width: 340, height: 340)
                    previewColumn("180% · 612 × 612", width: 612, height: 612)
                }
                .padding(24)
                .background(dark ? Color.black : Color.gray.opacity(0.12))
                .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: content)
                let rect = NSRect(x: 0, y: 0, width: 1286, height: 684)
                let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                host.frame = rect
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("preview render failed") }
                host.cacheDisplay(in: host.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/todo-preview-\(dark ? "dark" : "light").png"))
                window.orderOut(nil)
            }
            try renderTodoControls()
            return
        }

        let todoID = store.todoList!.id
        assert(store.visibleNotes().first?.id == todoID)
        let ordinary = store.create(body: "旧笔记仍然保留")
        _ = store.create(body: "另一条普通便签")
        assert(store.visibleNotes().first?.id == todoID)
        store.moveVisible(from: 0, to: 2)
        store.moveVisible(from: 2, to: 0)
        assert(store.visibleNotes().first?.id == todoID)
        store.setArchived(id: todoID, archived: true)
        assert(store.delete(id: todoID) == nil)
        store.togglePin(id: todoID)
        assert(store.todoList?.isPinned == true && store.todoList?.isArchived == false)
        AppSettings.shared.todoListEnabled = false
        assert(!store.visibleNotes().contains(where: { $0.id == todoID }))
        assert(store.libraryNotes().contains(where: { $0.id == todoID }))
        store.moveVisible(from: 0, to: 1)
        assert(store.todoList?.id == todoID)
        AppSettings.shared.todoListEnabled = true
        assert(store.visibleNotes().first?.id == todoID)
        let item = TodoItem(text: "enote-test-secret-task", category: "工作", priority: "high", dueAt: Date().addingTimeInterval(-120))
        store.addTodos([item])
        let originalNumber = store.todos().first { $0.id == item.id }!.number!
        assert(store.todo(identifier: String(originalNumber))?.id == item.id)
        assert(store.todo(identifier: String(format: "T%06lld", Int64(originalNumber)))?.id == item.id)
        assert(TaskSyntax.earliestOverdueDue(store.body(of: store.todoList!), now: Date()) != nil)
        var completed = item; completed.completed = true
        completed.number = 99999
        store.updateTodo(completed)
        assert(store.todos().first { $0.id == item.id }?.number == originalNumber)
        assert(TaskSyntax.earliestOverdueDue(store.body(of: store.todoList!), now: Date()) == nil)
        store.append(id: todoID, text: "快速捕捉待办一\n快速捕捉待办二")
        assert(store.todos().count == 3)
        store.updateBody(id: todoID, body: "不能把普通文本写入 TODO 数据")
        assert(store.todos().count == 3)
        assert(store.body(of: store.todoList!).contains("☑ [工作] [重要]"))
        let persisted = NoteStoreIO.load().first(where: { $0.id == todoID })!
        assert(persisted.kind == "todoList" && persisted.todoData != nil)
        assert(!persisted.body.contains(item.text) && !persisted.todoData!.contains(item.text))
        assert(store.lastSaveSucceeded)
        let oldJSON = try JSONEncoder().encode(ordinary)
        var oldObject = try JSONSerialization.jsonObject(with: oldJSON) as! [String: Any]
        oldObject.removeValue(forKey: "kind"); oldObject.removeValue(forKey: "todoData")
        let decoded = try JSONDecoder().decode(NoteRecord.self, from: JSONSerialization.data(withJSONObject: oldObject))
        assert(!decoded.isTodoList)

        // API 或其他便签触发刷新时，未落盘的编辑内容不能回滚。
        let editor = NoteEditorCoordinator(noteID: ordinary.id, deck: nil)
        let tv = EditorTextView()
        tv.string = store.body(id: ordinary.id)
        editor.attach(tv)
        tv.string = "尚未自动保存的输入"
        editor.scheduleSave()
        editor.syncExternalBodyIfNeeded()
        assert(tv.string == "尚未自动保存的输入")
        store.append(id: ordinary.id, text: "外部追加")
        editor.syncExternalBodyIfNeeded()
        assert(tv.string == "尚未自动保存的输入\n外部追加")
        editor.detach()

        // 使用真正的 NSHostingView / NSTextView 切换内容，验证协调器身份与未保存输入。
        let second = store.create(body: "B 卡片独立正文")
        let switchState = EditorSwitchState(id: ordinary.id)
        let host = NSHostingView(rootView: EditorSwitchView(state: switchState))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 240), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let editorA = EditorRegistry.shared.editor(for: ordinary.id)!
        assert(editorA.textView?.string == store.body(id: ordinary.id))
        editorA.textView?.string = "A 切换前未保存的正文"
        editorA.scheduleSave()
        switchState.id = second.id
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        let editorB = EditorRegistry.shared.editor(for: second.id)!
        assert(editorB !== editorA && editorB.textView?.string == "B 卡片独立正文")
        assert(store.body(id: ordinary.id) == "A 切换前未保存的正文")
        editorB.textView?.string = "B 修改后独立正文"
        editorB.scheduleSave()
        switchState.id = ordinary.id
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        assert(EditorRegistry.shared.editor(for: ordinary.id)?.textView?.string == "A 切换前未保存的正文")
        assert(store.body(id: second.id) == "B 修改后独立正文")
        window.contentView = nil

        // 仅 TODOList 的任务参与提醒，阈值边界、完成、改期和开关均生效。
        let watcher = OverdueWatcher.shared
        let now = Date()
        _ = store.create(body: TaskSyntax.settingDue("☐ 普通 note 到期也不弹出", to: now.addingTimeInterval(-3600)))
        let reminderTask = TodoItem(text: "即将到期的结构化任务", dueAt: now.addingTimeInterval(600))
        store.addTodos([reminderTask])
        AppSettings.shared.todoReminderMinutes = 10
        watcher.refresh(now: now.addingTimeInterval(-1))
        assert(!watcher.hasTodoReminder)
        watcher.refresh(now: now)
        assert(watcher.upcomingTaskIDs == [reminderTask.id] && watcher.reminderNoteID == todoID)
        watcher.refresh(now: now.addingTimeInterval(600))
        assert(watcher.overdueTaskIDs == [reminderTask.id] && watcher.isOverdue(todoID))
        AppSettings.shared.todoReminderEnabled = false
        watcher.refresh(now: now)
        assert(!watcher.hasTodoReminder)
        AppSettings.shared.todoReminderEnabled = true
        AppSettings.shared.todoListEnabled = false
        watcher.refresh(now: now)
        assert(!watcher.hasTodoReminder)
        AppSettings.shared.todoListEnabled = true
        var rescheduled = store.todo(identifier: reminderTask.id.uuidString)!
        rescheduled.dueAt = now.addingTimeInterval(3600)
        store.updateTodo(rescheduled)
        watcher.refresh(now: now)
        assert(!watcher.hasTodoReminder)
        rescheduled.dueAt = now.addingTimeInterval(60)
        rescheduled.completed = true
        store.updateTodo(rescheduled)
        watcher.refresh(now: now)
        assert(!watcher.hasTodoReminder)

        let count = store.todos().count
        let invalidBatch = Data(#"{"items":[{"text":"valid"},{"text":" "}]}"#.utf8)
        do { _ = try LocalAPIRouter.handle("POST", "/v1/todos", invalidBatch); fatalError("invalid batch accepted") }
        catch let error as APIError { assert(error.status == 400) }
        assert(store.todos().count == count)
        store.deleteTodo(id: item.id)
        assert(!store.todos().contains(where: { $0.id == item.id }))
        let last = store.addTodos([TodoItem(text: "待删除最高编号")])[0]
        assert(!store.deleteTodo(id: last.id))
        store.setTodoArchived(id: last.id, archived: true)
        assert(store.deleteTodo(id: last.id))
        let next = store.addTodos([TodoItem(text: "删除后不复用编号")])[0]
        assert(next.number! > last.number!)
        // 模拟前一个版本：有 UUID 但无编号，下一次启动应迁移且不丢任务。
        var legacyNotes = NoteStoreIO.load()
        let todoIndex = legacyNotes.firstIndex { $0.isTodoList }!
        let plain = NoteCrypto.shared.open(legacyNotes[todoIndex].todoData!)
        var legacyTasks = try JSONSerialization.jsonObject(with: Data(plain.utf8)) as! [[String: Any]]
        for index in legacyTasks.indices { legacyTasks[index].removeValue(forKey: "number") }
        let legacyData = try JSONSerialization.data(withJSONObject: legacyTasks)
        legacyNotes[todoIndex].todoData = NoteCrypto.shared.seal(String(data: legacyData, encoding: .utf8)!)
        legacyNotes[todoIndex].todoSequence = nil
        assert(NoteStoreIO.save(legacyNotes))
        print("PASS: 固定置顶/开关保留、独立 TODO 编号不复用、加密、编辑器 A→B→A 切换、提醒阈值/隔离/开关、批量验证")
    }

    @MainActor static func previewColumn(_ title: String, width: CGFloat, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 12)).foregroundColor(.secondary)
            TodoListView(onClose: {})
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}
