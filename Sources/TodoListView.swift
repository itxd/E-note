import SwiftUI
import AppKit

// 作者：韦冬 2220285589@qq.com
struct TodoListView: View {
    @ObservedObject var store = NoteStore.shared
    @State private var filter = 0
    @State private var selectedTagID: UUID?
    @State private var showingTagFilter = false
    @State private var draft = ""
    @State private var editing: TodoItem?
    @FocusState private var composing: Bool
    var onClose: (() -> Void)? = nil

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
                        TodoRow(item: item, edit: { editing = item }, toggle: {
                            guard var current = store.todos().first(where: { $0.id == item.id }) else { return }
                            current.completed.toggle()
                            store.updateTodo(current)
                        })
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
            composer
        }
        .background(TodoTheme.canvas)
        .tint(accent)
        .onChange(of: boundTags.map { $0.id }) { ids in
            if let selected = selectedTagID, !ids.contains(selected) { selectedTagID = nil }
        }
        .popover(item: $editing) { item in
            TodoDetailsView(item: item) { updated in
                // 详情编辑期间 API/其他窗口可能切换完成状态；保留最新状态。
                if let current = store.todos().first(where: { $0.id == updated.id }) {
                    var merged = updated
                    merged.completed = current.completed
                    merged.completedAt = current.completedAt
                    merged.archivedAt = current.archivedAt
                    merged.archiveRestoredAt = current.archiveRestoredAt
                    merged.tagIDs = current.tagIDs
                    store.updateTodo(merged)
                }
                editing = nil
            } delete: {
                store.deleteTodo(id: item.id)
                editing = nil
            }
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

    private var composer: some View {
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
        guard !text.isEmpty else { return }
        var item = TodoItem(text: text)
        item.tagIDs = selectedTagID.map { [$0] }
        store.addTodos([item])
        draft = ""
        if filter >= 2 { filter = 1 }
        composing = true
    }
}

struct TodoRow: View {
    @ObservedObject private var store = NoteStore.shared
    @ObservedObject private var watcher = OverdueWatcher.shared
    let item: TodoItem
    @State private var choosingTags = false
    @State private var inspectingTag: TodoTag?
    let edit: () -> Void
    let toggle: () -> Void
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
                ForEach(store.libraryNotes().filter { $0.linkedTodoID == item.id }) { note in
                    Button { AppDelegate.shared?.openLinkedNote(note.id) } label: {
                        Label("方案与执行记录", systemImage: "doc.text").font(.system(size: 10))
                    }.buttonStyle(.plain).foregroundColor(TodoTheme.accent)
                }
            }
            Spacer(minLength: 0)
            VStack(spacing: 6) {
            Button { store.setTodoArchived(id: item.id, archived: !item.isArchived) } label: {
                Image(systemName: item.isArchived ? "arrow.uturn.backward" : "archivebox")
                    .frame(width: 20, height: 20)
            }.buttonStyle(.plain).help(item.isArchived ? "恢复到列表（3 天后可再次自动归档）" : "归档任务")
            Button(action: edit) {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain).foregroundColor(.secondary).help("编辑优先级和到期时间")
            }
        }
        .padding(10)
        .background(TodoTheme.surface, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.055), lineWidth: 1))
    }
}

private struct TodoDetailsView: View {
    @State var item: TodoItem
    let save: (TodoItem) -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("编辑待办 · \(item.code)").font(.headline)
            TextField("待办内容", text: $item.text, axis: .vertical).lineLimit(2...5)
            Toggle("重要任务", isOn: Binding(get: { item.priority == "high" }, set: { item.priority = $0 ? "high" : "normal" }))
            Toggle("设置到期时间", isOn: Binding(get: { item.dueAt != nil }, set: { item.dueAt = $0 ? Date().addingTimeInterval(3600) : nil }))
            if item.dueAt != nil {
                DatePicker("到期", selection: Binding(get: { item.dueAt ?? Date() }, set: { item.dueAt = $0 }))
            }
            HStack {
                Button("删除任务", role: .destructive, action: delete)
                Spacer()
                Button("保存") {
                    item.text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    save(item)
                }
                .buttonStyle(.borderedProminent)
                .disabled(item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .tint(TodoTheme.accent)
        .padding(16)
        .frame(width: 300)
    }
}
