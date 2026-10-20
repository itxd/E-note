import SwiftUI
import AppKit

/// 每次渲染只解密一次任务和标签，供列表、计数和每一行共用。
private struct TodoSnapshot {
    let items: [TodoItem]
    let archived: [TodoItem]
    let done: Int
    let tags: [TodoTag]
    let boundTags: [TodoTag]
    let linkedTodoIDs: Set<UUID>

    init(store: NoteStore, tagID: UUID?, age: TodoAge, now: Date = Date()) {
        let all = store.todos()
        let matched = all.filter {
            (tagID == nil || ($0.tagIDs ?? []).contains(tagID!)) && age.contains($0, now: now)
        }
        items = matched.filter { !$0.isArchived }
        archived = matched.filter { $0.isArchived }
        done = items.filter { $0.completed }.count
        tags = store.tags()
        let bound = Set(all.flatMap { $0.tagIDs ?? [] })
        boundTags = tags.filter { bound.contains($0.id) }
        linkedTodoIDs = Set(store.notes.compactMap { $0.isTodoList ? nil : $0.linkedTodoID })
    }

    func tags(of item: TodoItem) -> [TodoTag] {
        guard let ids = item.tagIDs, !ids.isEmpty else { return [] }
        return tags.filter { ids.contains($0.id) }
    }
}

// 作者：韦冬 2220285589@qq.com
struct TodoListView: View {
    @ObservedObject var store = NoteStore.shared
    @State private var filter = 0
    @State private var selectedTagID: UUID?
    @State private var age = TodoAge.all
    @State private var showingFilter = false
    @State private var editing: TodoEditSession?
    @State private var editingDate: TodoEditSession?
    @State private var epoch = LocalProfile.epoch
    var onClose: (() -> Void)? = nil
    var onOpenNote: (UUID) -> Void = { AppDelegate.shared?.openLinkedNote($0) }

    private let accent = TodoTheme.accent
    private var filtering: Bool { selectedTagID != nil || age != .all }

    var body: some View {
        let snapshot = TodoSnapshot(store: store, tagID: selectedTagID, age: age)
        let filtered = filter == 3 ? snapshot.archived
            : snapshot.items.filter { filter == 0 || (filter == 1 ? !$0.completed : $0.completed) }
        VStack(spacing: 0) {
            heading(snapshot)
            HStack(spacing: 4) {
                ViewThatFits(in: .horizontal) {
                    statusPicker(snapshot, compact: false)
                    statusPicker(snapshot, compact: true)
                }
                Button { showingFilter = true } label: {
                    Image(systemName: filtering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        .font(.system(size: 16)).frame(width: 28, height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain).help("按时效、标签筛选").accessibilityLabel("筛选")
                    .popover(isPresented: $showingFilter) { filterMenu(snapshot.boundTags) }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            if filtering { activeFilters(snapshot.tags) }

            ScrollView {
                LazyVStack(spacing: 6) {
                    if filtered.isEmpty { emptyState(isEmpty: snapshot.items.isEmpty) }
                    ForEach(filtered) { item in
                        let session = TodoEditSession(original: item, epoch: epoch)
                        TodoRow(item: item, epoch: session.epoch, showQuickActions: filter < 2,
                                tags: snapshot.tags(of: item),
                                hasLinkedNote: snapshot.linkedTodoIDs.contains(item.id), edit: {
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
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            TodoComposer { text in
                var item = TodoItem(text: text)
                item.tagIDs = selectedTagID.map { [$0] }
                store.addTodos([item])
                if filter >= 2 { filter = 1 }
                if age == .older { age = .all }
                return store.lastSaveSucceeded
            }.id(epoch)
        }
        .background(TodoTheme.canvas)
        .tint(accent)
        .onChange(of: snapshot.boundTags.map { $0.id }) { ids in
            if let selected = selectedTagID, !ids.contains(selected) { selectedTagID = nil }
        }
        .onReceive(store.$notes) { _ in
            if epoch != LocalProfile.epoch {
                editing = nil; editingDate = nil; selectedTagID = nil; age = .all
                showingFilter = false; epoch = LocalProfile.epoch
            }
        }
        .popover(item: $editing) { session in
            TodoTitleEditor(session: session) { editing = nil }
        }
        .popover(item: $editingDate) { session in
            TodoDateEditor(session: session) { editingDate = nil }
        }
    }

    private func emptyState(isEmpty: Bool) -> some View {
        VStack(spacing: 8) {
            Image(systemName: isEmpty ? "tray" : "checkmark.seal")
                .font(.system(size: 26, weight: .light))
                .foregroundColor(accent.opacity(0.7))
            Text(filtering ? "没有符合筛选条件的任务" : (isEmpty ? "把想到的事，先放在这里" : "这里的任务都处理好了"))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func statusPicker(_ snapshot: TodoSnapshot, compact: Bool) -> some View {
        let count = snapshot.items.count
        return Picker("任务筛选", selection: $filter) {
            Text(compact ? "全部" : "全部 \(count)").tag(0)
            Text(compact ? "待办" : "待完成 \(count - snapshot.done)").tag(1)
            Text(compact ? "完成" : "已完成 \(snapshot.done)").tag(2)
            Text(compact ? "归档" : "归档 \(snapshot.archived.count)").tag(3)
        }.pickerStyle(.segmented).labelsHidden()
    }

    private func activeFilters(_ tags: [TodoTag]) -> some View {
        HStack(spacing: 6) {
            if age != .all {
                filterChip(age.title, systemImage: "clock") { age = .all }
            }
            if let id = selectedTagID, let tag = tags.first(where: { $0.id == id }) {
                filterChip(tag.name, systemImage: "tag.fill") { selectedTagID = nil }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func filterChip(_ title: String, systemImage: String, clear: @escaping () -> Void) -> some View {
        Button(action: clear) {
            HStack(spacing: 4) {
                Label(title, systemImage: systemImage).lineLimit(1)
                Image(systemName: "xmark").font(.system(size: 7, weight: .bold)).opacity(0.6)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(accent)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(accent.opacity(0.1), in: Capsule())
            .contentShape(Capsule())
        }.buttonStyle(.plain).help("清除筛选：\(title)")
    }

    private func filterMenu(_ boundTags: [TodoTag]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("时效").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
            ForEach(TodoAge.allCases) { option in
                filterOption(option.title, systemImage: "clock", selected: age == option) { age = option }
            }
            Divider().padding(.vertical, 6)
            Text("标签").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
            filterOption("全部标签", systemImage: "tag", selected: selectedTagID == nil) { selectedTagID = nil }
            if boundTags.isEmpty {
                Text("任务还没有绑定标签").font(.system(size: 11)).foregroundColor(.secondary).padding(6)
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(boundTags) { tag in
                        filterOption(tag.name, systemImage: "tag.fill", selected: selectedTagID == tag.id) { selectedTagID = tag.id }
                    }
                }
            }.frame(maxHeight: 200)
        }.padding(12).frame(width: 240)
    }

    private func filterOption(_ title: String, systemImage: String, selected: Bool,
                              choose: @escaping () -> Void) -> some View {
        Button(action: choose) {
            HStack {
                Label(title, systemImage: systemImage).lineLimit(1)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundColor(accent) }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(selected ? accent.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func heading(_ snapshot: TodoSnapshot) -> some View {
        let total = snapshot.items.count, done = snapshot.done
        return HStack(spacing: 10) {
            ZStack {
                Circle().stroke(accent.opacity(0.12), lineWidth: 2.5)
                Circle().trim(from: 0, to: total == 0 ? 0 : CGFloat(done) / CGFloat(total))
                    .stroke(accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "checklist").font(.system(size: 12, weight: .semibold))
                    .foregroundColor(accent)
            }
            .frame(width: 30, height: 30)
            .accessibilityLabel("已完成 \(done) 项，共 \(total) 项")
            VStack(alignment: .leading, spacing: 1) {
                Text(NoteRecord.todoListTitle).font(.system(size: 16, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
                Text(total == 0 ? "每一件小事，都算数" : "已完成 \(done) / \(total)")
                    .font(.system(size: 10)).foregroundColor(.secondary).monospacedDigit()
            }
            Spacer(minLength: 2)
            Button { TagWindowController.shared.show() } label: {
                Image(systemName: "tag").frame(width: 24, height: 24)
            }.buttonStyle(.plain).foregroundColor(.secondary).help("标签管理").accessibilityLabel("标签管理")
            Button { AppDelegate.shared?.showSettings() } label: {
                Image(systemName: "gearshape").frame(width: 24, height: 24)
            }.buttonStyle(.plain).foregroundColor(.secondary).help("设置").accessibilityLabel("设置")
            if let onClose = onClose {
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .help("收起待办清单")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
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
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderedProminent)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("添加待办（回车）")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(TodoTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(accent.opacity(composing ? 0.35 : 0.12), lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, submit(text) else { return }
        draft = ""
        composing = true
    }
}

/// 一行三层：编号与全部操作同一横栏 → 标题 → 已绑定标签。添加标签按钮仅在悬停时出现。
struct TodoRow: View {
    @ObservedObject private var watcher = OverdueWatcher.shared
    let item: TodoItem
    let epoch: UUID
    let showQuickActions: Bool
    var tags: [TodoTag] = []
    var hasLinkedNote = false
    @State private var hovering = false
    @State private var choosingTags = false
    @State private var inspectingTag: TodoTag?
    @State private var confirmingDelete = false
    @State private var errorMessage: String?
    let edit: () -> Void
    let editDate: () -> Void
    let toggle: () -> Void
    var openNote: (UUID) -> Void = { AppDelegate.shared?.openLinkedNote($0) }
    private var store: NoteStore { .shared }
    private var dueSoon: Bool { watcher.upcomingTaskIDs.contains(item.id) }
    private var important: Bool { item.priority == "high" }
    private var accent: Color { item.overdue ? .red : (dueSoon || important ? .orange : TodoTheme.accent) }
    private var dueColor: Color { item.overdue ? .red : (dueSoon ? .orange : TodoTheme.accent) }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: toggle) {
                Image(systemName: item.completed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17, weight: .light))
                    .foregroundColor(item.completed ? TodoTheme.accent : accent.opacity(0.8))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.completed ? "标为待完成：\(item.text)" : "完成：\(item.text)")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    ViewThatFits(in: .horizontal) {
                        leadingBar(.full)
                        leadingBar(.short)
                        leadingBar(.icon)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    trailingActions.fixedSize()
                }
                .frame(minHeight: 20)
                Text(item.text)
                    .font(.system(size: 12, weight: .medium))
                    .strikethrough(item.completed)
                    .foregroundColor(item.completed ? .secondary : .primary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(item.text)
                if !tags.isEmpty { tagStrip }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(TodoTheme.surface, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .stroke(hovering ? TodoTheme.accent.opacity(0.28) : Color.primary.opacity(0.055), lineWidth: 1))
        .onHover { hovering = $0 }
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

    private enum LabelStyle { case full, short, icon }

    private func leadingBar(_ style: LabelStyle) -> some View {
        HStack(spacing: 8) {
            Text(item.code)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .fixedSize()
                .contextMenu {
                    Button("复制任务编号") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.code, forType: .string)
                    }
                }
            if showQuickActions {
                dueButton(style)
                importanceButton(style)
            } else {
                if important { Image(systemName: "flag.fill").foregroundColor(.orange).help("重要") }
                if let due = item.dueAt { dueText(due).foregroundColor(item.overdue ? .red : .secondary) }
            }
        }
        .font(.system(size: 10))
    }

    private func dueText(_ due: Date) -> some View {
        Text(due, format: .dateTime.month(.defaultDigits).day().hour().minute()).monospacedDigit().lineLimit(1)
    }

    private func dueButton(_ style: LabelStyle) -> some View {
        Button(action: editDate) {
            HStack(spacing: 3) {
                Image(systemName: "calendar")
                if let due = item.dueAt {
                    if style != .icon { dueText(due) }
                } else if style != .icon {
                    Text(style == .full ? "设置时间" : "时间")
                }
            }
            .fixedSize().padding(.vertical, 2).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundColor(item.dueAt == nil ? .secondary : dueColor)
            .help(item.dueAt == nil ? "设置到期时间" : "修改或清除到期时间").accessibilityLabel("设置时间：\(item.text)")
    }

    private func importanceButton(_ style: LabelStyle) -> some View {
        Button {
            do { try store.editTodo(id: item.id, epoch: epoch, change: .toggleImportance) }
            catch { errorMessage = error.localizedDescription }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: important ? "flag.fill" : "flag")
                if style == .full { Text(important ? "取消重要" : "设为重要") }
                if style == .short { Text("重要") }
            }
            .fixedSize().padding(.vertical, 2).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundColor(important ? .orange : .secondary)
            .help(important ? "取消重要任务" : "设为重要任务")
            .accessibilityLabel("\(important ? "取消重要任务" : "设为重要任务")：\(item.text)")
    }

    private var trailingActions: some View {
        let showTagButton = hovering || choosingTags
        return HStack(spacing: 0) {
            iconButton("tag", help: "添加或修改绑定标签") { choosingTags = true }
                .opacity(showTagButton ? 1 : 0)
                .allowsHitTesting(showTagButton)
                .accessibilityHidden(!showTagButton)
                .popover(isPresented: $choosingTags) { TodoTagPicker(itemID: item.id) }
            iconButton("pencil", help: "修改待办标题") { edit() }
                .accessibilityLabel("修改待办标题：\(item.text)")
            iconButton(item.isArchived ? "arrow.uturn.backward" : "archivebox",
                       help: item.isArchived ? "恢复到列表（3 天后可再次自动归档）" : "归档任务") {
                guard epoch == LocalProfile.epoch,
                      let current = store.todo(identifier: item.id.uuidString) else { return }
                store.setTodoArchived(id: item.id, archived: !current.isArchived)
            }
            iconButton(hasLinkedNote ? "doc.text" : "square.and.pencil",
                       help: hasLinkedNote ? "查看关联便签 · \(item.code)" : "创建关联便签 · \(item.code)",
                       tint: hasLinkedNote ? TodoTheme.accent : nil) {
                do {
                    let note = try store.ensureLinkedNote(todoID: item.id, epoch: epoch)
                    openNote(note.id)
                } catch { errorMessage = error.localizedDescription }
            }
            .accessibilityLabel(hasLinkedNote ? "查看关联便签" : "创建关联便签")
            if item.canDelete {
                iconButton("trash", help: "删除任务", tint: .red) { confirmingDelete = true }
                    .accessibilityLabel("删除任务：\(item.text)")
            }
        }
        .opacity(hovering ? 1 : 0.6)
    }

    private func iconButton(_ systemImage: String, help: String, tint: Color? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundColor(tint ?? .secondary).help(help)
    }

    private var tagStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(tags) { tag in
                    Button { inspectingTag = tag } label: {
                        Label(tag.name, systemImage: "tag.fill").font(.system(size: 9.5))
                            .foregroundColor(TodoTheme.accent)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(TodoTheme.accent.opacity(0.1), in: Capsule())
                            .contentShape(Capsule())
                    }.buttonStyle(.plain)
                }
            }
        }
        .popover(item: $inspectingTag) { tag in TagInfoView(tagID: tag.id) }
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
