import SwiftUI
import AppKit

// 作者：韦冬 2220285589@qq.com
struct TodoListView: View {
    @ObservedObject var store = NoteStore.shared
    @State private var filter = 0
    @State private var selectedTagID: UUID?
    @State private var showingTagFilter = false
    @State private var editing: TodoEditSession?
    @State private var editingDate: TodoEditSession?
    @State private var epoch = LocalProfile.epoch
    var onClose: (() -> Void)? = nil
    var onOpenNote: (UUID) -> Void = { AppDelegate.shared?.openLinkedNote($0) }

    private let accent = TodoTheme.accent
    private var taggedItems: [TodoItem] {
        store.todos().filter { selectedTagID == nil || ($0.tagIDs ?? []).contains(selectedTagID!) }
    }
    private var boundTags: [TodoTag] {
        let ids = Set(store.todos().flatMap { $0.tagIDs ?? [] })
        return store.tags().filter { ids.contains($0.id) }
    }
    private var items: [TodoItem] { taggedItems.filter { !$0.isArchived } }
    private var archived: [TodoItem] { taggedItems.filter { $0.isArchived } }
    private var done: Int { items.filter { $0.completed }.count }
    private var filtered: [TodoItem] {
        filter == 3 ? archived : items.filter { filter == 0 || (filter == 1 ? !$0.completed : $0.completed) }
    }

    var body: some View {
        VStack(spacing: 0) {
            heading
            HStack(spacing: 4) {
                ViewThatFits(in: .horizontal) {
                    statusPicker(compact: false)
                    statusPicker(compact: true)
                }
                Button { showingTagFilter = true } label: {
                    Image(systemName: selectedTagID == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                        .font(.system(size: 16)).frame(width: 28, height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain).help("按标签筛选").accessibilityLabel("按标签筛选")
                    .popover(isPresented: $showingTagFilter) { tagFilter }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            if let id = selectedTagID, let tag = store.tags().first(where: { $0.id == id }) {
                HStack {
                    Label(tag.name, systemImage: "tag.fill").lineLimit(1)
                    Spacer()
                    Button { selectedTagID = nil } label: {
                        Image(systemName: "xmark.circle.fill").frame(width: 24, height: 24).contentShape(Rectangle())
                    }.buttonStyle(.plain).help("清除标签筛选")
                }.font(.system(size: 10)).padding(.horizontal, 14).padding(.bottom, 8)
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    if filtered.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: items.isEmpty ? "tray" : "checkmark.seal")
                                .font(.system(size: 26, weight: .light))
                                .foregroundColor(accent.opacity(0.7))
                            Text(selectedTagID != nil ? "没有符合筛选条件的任务" : (items.isEmpty ? "把想到的事，先放在这里" : "这里的任务都处理好了"))
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    }
                    ForEach(filtered) { item in
                        let session = TodoEditSession(original: item, epoch: epoch)
                        TodoRow(item: item, epoch: session.epoch, showQuickActions: filter < 2, edit: {
                            editingDate = nil
                            editing = session
                        }, editDate: {
                            editing = nil
                            editingDate = session
                        }, toggle: {
                            guard session.epoch == LocalProfile.epoch else { return }
                            guard var current = store.todos().first(where: { $0.id == item.id }) else { return }
                            current.completed.toggle()
                            store.updateTodo(current)
                        }, openNote: onOpenNote).id("\(epoch)-\(item.id)")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
            TodoComposer { text in
                var item = TodoItem(text: text)
                item.tagIDs = selectedTagID.map { [$0] }
                store.addTodos([item])
                if filter >= 2 { filter = 1 }
                return store.lastSaveSucceeded
            }.id(epoch)
        }
        .background(TodoTheme.canvas)
        .tint(accent)
        .onChange(of: boundTags.map { $0.id }) { ids in
            if let selected = selectedTagID, !ids.contains(selected) { selectedTagID = nil }
        }
        .onReceive(store.$notes) { _ in
            if epoch != LocalProfile.epoch {
                editing = nil; editingDate = nil; selectedTagID = nil
                showingTagFilter = false; epoch = LocalProfile.epoch
            }
        }
        .popover(item: $editing) { session in
            TodoTitleEditor(session: session) { editing = nil }
        }
        .popover(item: $editingDate) { session in
            TodoDateEditor(session: session) { editingDate = nil }
        }
    }

    private func statusPicker(compact: Bool) -> some View {
        Picker("任务筛选", selection: $filter) {
            Text(compact ? "全部" : "全部 \(items.count)").tag(0)
            Text(compact ? "待办" : "待完成 \(items.count - done)").tag(1)
            Text(compact ? "完成" : "已完成 \(done)").tag(2)
            Text(compact ? "归档" : "归档 \(archived.count)").tag(3)
        }.pickerStyle(.segmented).labelsHidden()
    }

    private var tagFilter: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("按标签筛选").font(.headline)
            Button { selectedTagID = nil; showingTagFilter = false } label: {
                HStack { Text("全部标签"); Spacer(); if selectedTagID == nil { Image(systemName: "checkmark") } }
                    .padding(8).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if boundTags.isEmpty { Text("任务还没有绑定标签").foregroundColor(.secondary) }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(boundTags) { tag in
                        Button { selectedTagID = tag.id; showingTagFilter = false } label: {
                            HStack {
                                Label(tag.name, systemImage: "tag"); Spacer()
                                if selectedTagID == tag.id { Image(systemName: "checkmark") }
                            }.padding(8).frame(maxWidth: .infinity).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(maxHeight: 260)
        }.padding(14).frame(width: 260)
    }

    private var heading: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().stroke(accent.opacity(0.12), lineWidth: 3)
                Circle().trim(from: 0, to: items.isEmpty ? 0 : CGFloat(done) / CGFloat(items.count))
                    .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "checklist").font(.system(size: 14, weight: .semibold))
                    .foregroundColor(accent)
            }
            .frame(width: 34, height: 34)
            .accessibilityLabel("已完成 \(done) 项，共 \(items.count) 项")
            VStack(alignment: .leading, spacing: 2) {
                Text(NoteRecord.todoListTitle).font(.system(size: 17, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
                Text(items.isEmpty ? "每一件小事，都算数" : "已完成 \(done) / \(items.count)")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            Spacer(minLength: 2)
            Button { TagWindowController.shared.show() } label: {
                Image(systemName: "tag").frame(width: 24, height: 24)
            }.buttonStyle(.plain).help("标签管理").accessibilityLabel("标签管理")
            Button { AppDelegate.shared?.showSettings() } label: {
                Image(systemName: "gearshape").frame(width: 24, height: 24)
            }.buttonStyle(.plain).help("设置").accessibilityLabel("设置")
            if let onClose = onClose {
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .help("收起待办清单")
            }
        }
        .padding(14)
    }

}

// Draft changes invalidate only this small view, never the decrypted task list.
struct TodoComposer: View {
    let submit: (String) -> Bool
    @State private var draft = ""
    @FocusState private var composing: Bool
    private let accent = TodoTheme.accent

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill").foregroundColor(accent)
            TextField("添加一个待办…", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($composing)
                .onSubmit(add)
            Button(action: add) {
                Image(systemName: "arrow.up").font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.borderedProminent)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("添加待办（回车）")
        }
        .padding(10)
        .background(TodoTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(accent.opacity(0.12), lineWidth: 1))
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, submit(text) else { return }
        draft = ""
        composing = true
    }
}

struct TodoRow: View {
    @ObservedObject private var store = NoteStore.shared
    @ObservedObject private var watcher = OverdueWatcher.shared
    let item: TodoItem
    let epoch: UUID
    let showQuickActions: Bool
    @State private var choosingTags = false
    @State private var inspectingTag: TodoTag?
    @State private var confirmingDelete = false
    @State private var errorMessage: String?
    let edit: () -> Void
    let editDate: () -> Void
    let toggle: () -> Void
    var openNote: (UUID) -> Void = { AppDelegate.shared?.openLinkedNote($0) }
    private var dueSoon: Bool { watcher.upcomingTaskIDs.contains(item.id) }
    private var accent: Color { item.overdue ? .red : (dueSoon || item.priority == "high" ? .orange : TodoTheme.accent) }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Button(action: toggle) {
                Image(systemName: item.completed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19, weight: .light))
                    .foregroundColor(item.completed ? TodoTheme.accent : accent.opacity(0.75))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.completed ? "标为待完成：\(item.text)" : "完成：\(item.text)")
            VStack(alignment: .leading, spacing: 6) {
                Text(item.code)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .contextMenu {
                        Button("复制任务编号") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(item.code, forType: .string)
                        }
                    }
                Text(item.text)
                    .font(.system(size: 12, weight: .medium))
                    .strikethrough(item.completed)
                    .foregroundColor(item.completed ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                if item.priority == "high" || item.dueAt != nil {
                HStack(spacing: 5) {
                    if item.priority == "high" { Image(systemName: "flag.fill").foregroundColor(.orange).help("重要") }
                    if let due = item.dueAt {
                        Text(due, format: .dateTime.month().day().hour().minute())
                            .lineLimit(1)
                            .foregroundColor(item.overdue ? .red : (dueSoon ? .orange : .secondary))
                    }
                }
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                }
                if showQuickActions {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { quickActions(compact: false) }
                        HStack(spacing: 10) { quickActions(compact: true) }
                    }
                    .font(.system(size: 10))
                    .padding(.vertical, 2)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(store.tags().filter { (item.tagIDs ?? []).contains($0.id) }) { tag in
                            Button { inspectingTag = tag } label: {
                                Label(tag.name, systemImage: "tag.fill").font(.system(size: 10))
                                    .padding(.horizontal, 7).padding(.vertical, 4)
                                    .background(TodoTheme.accent.opacity(0.1), in: Capsule())
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                        Button { choosingTags = true } label: {
                            Label("标签", systemImage: "plus").font(.system(size: 10))
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .background(TodoTheme.accent.opacity(0.07), in: Capsule())
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).help("添加或修改绑定标签")
                    }
                }
                .popover(isPresented: $choosingTags) { TodoTagPicker(itemID: item.id) }
                .popover(item: $inspectingTag) { tag in TagInfoView(tagID: tag.id) }

            }
            Spacer(minLength: 0)
            VStack(spacing: 6) {
            Button {
                do {
                    let note = try store.ensureLinkedNote(todoID: item.id, epoch: epoch)
                    openNote(note.id)
                } catch { errorMessage = error.localizedDescription }
            } label: {
                Image(systemName: store.linkedNote(todoID: item.id) == nil ? "square.and.pencil" : "doc.text")
                    .frame(width: 20, height: 20)
            }.buttonStyle(.plain).foregroundColor(TodoTheme.accent)
                .help(store.linkedNote(todoID: item.id) == nil ? "创建关联便签 · \(item.code)" : "查看关联便签 · \(item.code)")
                .accessibilityLabel(store.linkedNote(todoID: item.id) == nil ? "创建关联便签" : "查看关联便签")
            Button {
                guard epoch == LocalProfile.epoch,
                      let current = store.todo(identifier: item.id.uuidString) else { return }
                store.setTodoArchived(id: item.id, archived: !current.isArchived)
            } label: {
                Image(systemName: item.isArchived ? "arrow.uturn.backward" : "archivebox")
                    .frame(width: 20, height: 20)
            }.buttonStyle(.plain).help(item.isArchived ? "恢复到列表（3 天后可再次自动归档）" : "归档任务")
            Button(action: edit) {
                Image(systemName: "pencil").font(.system(size: 12, weight: .semibold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain).foregroundColor(.secondary).help("修改待办标题").accessibilityLabel("修改待办标题：\(item.text)")
            if item.canDelete {
                Button { confirmingDelete = true } label: {
                    Image(systemName: "trash").frame(width: 20, height: 20)
                }.buttonStyle(.plain).foregroundColor(.red)
                    .help("删除任务").accessibilityLabel("删除任务：\(item.text)")
            }
            }
        }
        .padding(10)
        .background(TodoTheme.surface, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.055), lineWidth: 1))
        .confirmationDialog("删除 \(item.code)？", isPresented: $confirmingDelete) {
            Button("删除任务", role: .destructive) {
                if !store.deleteTodo(id: item.id, epoch: epoch) {
                    errorMessage = "删除未成功。请确认任务仍为已完成或已归档、账号未切换，并检查数据保存状态。"
                }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("删除后无法恢复。") }
        .alert("操作未完成", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    @ViewBuilder private func quickActions(compact: Bool) -> some View {
        Button(action: editDate) {
            Label(compact ? "时间" : "设置时间", systemImage: "calendar")
                .fixedSize().padding(.vertical, 3).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundColor(item.dueAt == nil ? .secondary : TodoTheme.accent)
            .help("设置、修改或清除到期时间").accessibilityLabel("设置时间：\(item.text)")
        Button {
            do { try store.editTodo(id: item.id, epoch: epoch, change: .toggleImportance) }
            catch { errorMessage = error.localizedDescription }
        } label: {
            Label(compact ? "重要" : (item.priority == "high" ? "取消重要" : "设为重要"), systemImage: item.priority == "high" ? "flag.fill" : "flag")
                .fixedSize().padding(.vertical, 3).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundColor(item.priority == "high" ? .orange : .secondary)
            .help(item.priority == "high" ? "取消重要任务" : "设为重要任务")
            .accessibilityLabel("\(item.priority == "high" ? "取消重要任务" : "设为重要任务")：\(item.text)")
    }
}

struct TodoTitleEditor: View {
    let session: TodoEditSession
    let close: () -> Void
    @State private var text: String
    @State private var errorMessage = ""

    init(session: TodoEditSession, close: @escaping () -> Void) {
        self.session = session; self.close = close
        _text = State(initialValue: session.original.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("修改标题 · \(session.original.code)").font(.headline)
            TextField("待办标题", text: $text, axis: .vertical).lineLimit(2...5)
            if !errorMessage.isEmpty { Text(errorMessage).font(.caption).foregroundColor(.red) }
            HStack {
                Button("取消", action: close)
                Spacer()
                Button("保存") {
                    do {
                        try NoteStore.shared.editTodo(id: session.id, epoch: session.epoch,
                                                      change: .title(text, replacing: session.original.text))
                        close()
                    } catch { errorMessage = error.localizedDescription }
                }
                .buttonStyle(TodoEditorButtonStyle(prominent: true))
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > 10000)
            }
        }
        .textFieldStyle(.roundedBorder)
        .buttonStyle(TodoEditorButtonStyle())
        .tint(TodoTheme.accent)
        .padding(16)
        .frame(width: 300)
    }
}

struct TodoDateEditor: View {
    let session: TodoEditSession
    let close: () -> Void
    @State private var enabled: Bool
    @State private var date: Date
    @State private var errorMessage = ""

    init(session: TodoEditSession, close: @escaping () -> Void) {
        self.session = session; self.close = close
        _enabled = State(initialValue: true)
        _date = State(initialValue: session.original.dueAt ?? Date().addingTimeInterval(3600))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("设置时间 · \(session.original.code)").font(.headline)
            Toggle("设置到期时间", isOn: $enabled)
            if enabled { DatePicker("到期", selection: $date, displayedComponents: [.date, .hourAndMinute]) }
            if !errorMessage.isEmpty { Text(errorMessage).font(.caption).foregroundColor(.red) }
            HStack {
                Button("取消", action: close)
                if session.original.dueAt != nil { Button("清除时间") { save(nil) } }
                Spacer()
                Button("保存") { save(enabled ? date : nil) }.buttonStyle(TodoEditorButtonStyle(prominent: true))
            }
        }.padding(16).frame(width: 300).tint(TodoTheme.accent).buttonStyle(TodoEditorButtonStyle())
    }

    private func save(_ value: Date?) {
        do {
            try NoteStore.shared.editTodo(id: session.id, epoch: session.epoch,
                                          change: .dueDate(value, replacing: session.original.dueAt))
            close()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct TodoEditorButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .foregroundColor(prominent ? .white : .primary)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(prominent ? TodoTheme.accent : TodoTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
    }
}
