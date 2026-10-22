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
    /// 0 全部 · 1 待完成 · 2 已完成 · 3 归档；默认先看待完成。
    @State private var filter = 1
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
            HStack(spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    statusPicker(snapshot, compact: false)
                    statusPicker(snapshot, compact: true)
                }
                filterButton(snapshot.boundTags)
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
                .padding(.top, 2)
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
        .background(TodoBackdrop())
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
        VStack(spacing: 10) {
            Image(systemName: filtering ? "line.3.horizontal.decrease" : (isEmpty ? "sparkles" : "checkmark.seal"))
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(TodoTheme.gradient)
                .frame(width: 48, height: 48)
                .background(Circle().fill(accent.opacity(0.08)))
            Text(filtering ? "没有符合筛选条件的任务" : (isEmpty ? "把想到的事，先放在这里" : "这里的任务都处理好了"))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private func statusPicker(_ snapshot: TodoSnapshot, compact: Bool) -> some View {
        let count = snapshot.items.count
        return TodoSegments(selection: $filter, options: [
            ("全部", compact ? nil : count),
            (compact ? "待办" : "待完成", compact ? nil : count - snapshot.done),
            (compact ? "完成" : "已完成", compact ? nil : snapshot.done),
            ("归档", compact ? nil : snapshot.archived.count),
        ])
    }

    private func filterButton(_ boundTags: [TodoTag]) -> some View {
        Button { showingFilter = true } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(filtering ? AnyShapeStyle(TodoTheme.gradient) : AnyShapeStyle(Color.secondary))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(filtering ? accent.opacity(0.12) : TodoTheme.track))
                .overlay(alignment: .topTrailing) {
                    if filtering { Circle().fill(TodoTheme.gradient).frame(width: 6, height: 6).offset(x: -4, y: 4) }
                }
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help("按时效、标签筛选").accessibilityLabel("筛选")
            .popover(isPresented: $showingFilter) { filterMenu(boundTags) }
    }

    private func activeFilters(_ tags: [TodoTag]) -> some View {
        HStack(spacing: 6) {
            if age != .all {
                filterChip(age.title, systemImage: "clock") { age = .all }
            }
            if let id = selectedTagID, let tag = tags.first(where: { $0.id == id }) {
                filterChip(tag.name, systemImage: "number") { selectedTagID = nil }
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
            .background(Capsule().fill(accent.opacity(0.1)))
            .overlay(Capsule().strokeBorder(accent.opacity(0.18), lineWidth: 0.6))
            .contentShape(Capsule())
        }.buttonStyle(.plain).help("清除筛选：\(title)")
    }

    private func filterMenu(_ boundTags: [TodoTag]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            menuHeader("时效")
            ForEach(TodoAge.allCases) { option in
                filterOption(option.title, systemImage: "clock", selected: age == option) { age = option }
            }
            Divider().padding(.vertical, 6)
            menuHeader("标签")
            filterOption("全部标签", systemImage: "number", selected: selectedTagID == nil) { selectedTagID = nil }
            if boundTags.isEmpty {
                Text("任务还没有绑定标签").font(.system(size: 11)).foregroundColor(.secondary).padding(8)
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(boundTags) { tag in
                        filterOption(tag.name, systemImage: "number", selected: selectedTagID == tag.id) { selectedTagID = tag.id }
                    }
                }
            }.frame(maxHeight: 200)
        }.padding(10).frame(width: 236)
    }

    private func menuHeader(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
            .padding(.horizontal, 8).padding(.bottom, 2)
    }

    private func filterOption(_ title: String, systemImage: String, selected: Bool,
                              choose: @escaping () -> Void) -> some View {
        Button(action: choose) {
            HStack {
                Label(title, systemImage: systemImage).lineLimit(1)
                Spacer()
                if selected { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(accent) }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? accent.opacity(0.1) : Color.clear))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func heading(_ snapshot: TodoSnapshot) -> some View {
        let total = snapshot.items.count, done = snapshot.done
        let progress = total == 0 ? 0 : CGFloat(done) / CGFloat(total)
        return HStack(spacing: 10) {
            ZStack {
                Circle().stroke(TodoTheme.track, lineWidth: 3)
                Circle().trim(from: 0, to: progress)
                    .stroke(TodoTheme.ringGradient, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: TodoTheme.accentAlt.opacity(progress > 0 ? 0.35 : 0), radius: 3)
                Image(systemName: "checklist").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TodoTheme.gradient)
            }
            .frame(width: 30, height: 30)
            .animation(.easeOut(duration: 0.35), value: progress)
            .accessibilityLabel("已完成 \(done) 项，共 \(total) 项")
            VStack(alignment: .leading, spacing: 2) {
                Text(NoteRecord.todoListTitle).font(.system(size: 15, weight: .semibold)).tracking(-0.2)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(total == 0 ? "每一件小事，都算数" : "已完成 \(done) / \(total) · \(Int((progress * 100).rounded()))%")
                    .font(.system(size: 10, weight: .medium)).foregroundColor(.secondary).monospacedDigit()
            }
            Spacer(minLength: 2)
            HStack(spacing: 0) {
                headerButton("number", help: "标签管理") { TagWindowController.shared.show() }
                headerButton("gearshape", help: "设置") { AppDelegate.shared?.showSettings() }
                if let onClose = onClose { headerButton("xmark", help: "收起待办清单", action: onClose) }
            }
            .padding(2)
            .background(Capsule().fill(TodoTheme.track))
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private func headerButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.system(size: 10.5, weight: .semibold))
                .frame(width: 24, height: 22).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundColor(.secondary).help(help).accessibilityLabel(help)
    }
}

/// 自绘分段控件：滑块随选中项移动，替代系统分段控件。
private struct TodoSegments: View {
    @Binding var selection: Int
    let options: [(title: String, count: Int?)]
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let selected = selection == index
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { selection = index }
                } label: {
                    HStack(spacing: 3) {
                        Text(options[index].title)
                        if let count = options[index].count {
                            Text("\(count)").monospacedDigit()
                                .foregroundColor(selected ? TodoTheme.accent : Color.secondary.opacity(0.75))
                        }
                    }
                    .font(.system(size: 11, weight: selected ? .semibold : .medium))
                    .foregroundColor(selected ? .primary : .secondary)
                    .lineLimit(1).fixedSize()
                    .padding(.horizontal, 7)
                    .frame(maxWidth: .infinity, minHeight: 24)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(TodoTheme.raised)
                                .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                                .matchedGeometryEffect(id: "segment", in: namespace)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(TodoTheme.track))
    }
}

// Draft changes invalidate only this small view, never the decrypted task list.
struct TodoComposer: View {
    let submit: (String) -> Bool
    @State private var draft = ""
    @FocusState private var composing: Bool
    private let accent = TodoTheme.accent
    private var isEmpty: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .strokeBorder(composing ? AnyShapeStyle(TodoTheme.gradient) : AnyShapeStyle(Color.secondary.opacity(0.45)),
                              style: StrokeStyle(lineWidth: 1.2, dash: [2.2, 2.2]))
                .frame(width: 16, height: 16)
            TextField("添加一个待办…", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($composing)
                .onSubmit(add)
            ZStack {
                if isEmpty {
                    Text("↩").font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(.secondary)
                        .frame(width: 22, height: 18)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(TodoTheme.track))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(TodoTheme.hairline, lineWidth: 0.6))
                        .transition(.opacity)
                        .accessibilityHidden(true)
                } else {
                    Button(action: add) {
                        Image(systemName: "arrow.up").font(.system(size: 10.5, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(TodoTheme.gradient))
                            .shadow(color: TodoTheme.accentAlt.opacity(0.35), radius: 4, y: 1)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("添加待办（回车）")
                    .accessibilityLabel("添加待办")
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .frame(width: 26, height: 26)
        }
        .padding(.leading, 12)
        .padding(.trailing, 7)
        .frame(height: 40)
        // 阴影只挂在底板形状上：挂在整行会随输入框每次重绘重新计算。
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(TodoTheme.cardHover)
            .shadow(color: TodoTheme.accentAlt.opacity(composing ? 0.2 : 0.06), radius: composing ? 14 : 6, y: 4))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(TodoTheme.auroraStroke, lineWidth: composing ? 1.2 : 0.8)
            .opacity(composing ? 0.9 : 0.35))
        .animation(.easeOut(duration: 0.2), value: composing)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isEmpty)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 12)
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
    private var dueColor: Color { item.overdue ? .red : (dueSoon ? TodoTheme.important : TodoTheme.accent) }
    /// 左侧细条只标记需要注意的任务：逾期为红，重要或即将到期为橙。
    private var marker: Color? {
        guard !item.completed else { return nil }
        if item.overdue { return .red }
        return important || dueSoon ? TodoTheme.important : nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            checkbox
            VStack(alignment: .leading, spacing: 4) {
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
                    .font(.system(size: 12.5, weight: .medium))
                    .strikethrough(item.completed, color: .secondary)
                    .foregroundColor(item.completed ? .secondary : .primary)
                    .lineSpacing(1.5)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(item.text)
                if !tags.isEmpty { tagStrip }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(hovering ? TodoTheme.cardHover : TodoTheme.card)
            .shadow(color: TodoTheme.accent.opacity(hovering ? 0.12 : 0), radius: hovering ? 8 : 0, y: 2))
        .overlay(alignment: .leading) {
            if let marker = marker {
                Capsule().fill(marker).frame(width: 2.5).padding(.vertical, 10).padding(.leading, 2.5)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(hovering ? AnyShapeStyle(TodoTheme.accent.opacity(0.3)) : AnyShapeStyle(TodoTheme.cardStroke),
                          lineWidth: 0.8))
        .animation(.easeOut(duration: 0.15), value: hovering)
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

    private var checkbox: some View {
        Button(action: toggle) {
            ZStack {
                if item.completed {
                    Circle().fill(TodoTheme.gradient)
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundColor(.white)
                } else {
                    Circle().strokeBorder(marker ?? (hovering ? TodoTheme.accent : Color.secondary.opacity(0.5)),
                                          lineWidth: 1.3)
                }
            }
            .frame(width: 16, height: 16)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.completed ? "标为待完成：\(item.text)" : "完成：\(item.text)")
    }

    private enum LabelStyle { case full, short, icon }

    private func leadingBar(_ style: LabelStyle) -> some View {
        HStack(spacing: 4) {
            Text(item.code)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.horizontal, 4).padding(.vertical, 1.5)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(TodoTheme.track))
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
                if important { chip(Image(systemName: "flag.fill"), nil, tint: TodoTheme.important, active: true).help("重要") }
                if let due = item.dueAt {
                    chip(Image(systemName: "calendar"), dueText(due), tint: item.overdue ? .red : .secondary, active: false)
                }
            }
        }
    }

    private func dueText(_ due: Date) -> Text {
        Text(due, format: .dateTime.month(.defaultDigits).day().hour().minute())
    }

    private func chip(_ icon: Image, _ text: Text?, tint: Color, active: Bool) -> some View {
        HStack(spacing: 3) {
            icon
            if let text = text { text.monospacedDigit().lineLimit(1) }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundColor(active ? tint : .secondary)
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(active ? tint.opacity(0.12) : Color.clear))
        .fixedSize()
        .contentShape(Rectangle())
    }

    private func dueButton(_ style: LabelStyle) -> some View {
        let label: Text? = style == .icon ? nil
            : item.dueAt.map(dueText) ?? Text(style == .full ? "设置时间" : "时间")
        return Button(action: editDate) {
            chip(Image(systemName: "calendar"), label, tint: dueColor, active: item.dueAt != nil)
        }.buttonStyle(.plain)
            .help(item.dueAt == nil ? "设置到期时间" : "修改或清除到期时间").accessibilityLabel("设置时间：\(item.text)")
    }

    private func importanceButton(_ style: LabelStyle) -> some View {
        let label: Text? = style == .icon ? nil
            : Text(style == .full ? (important ? "取消重要" : "设为重要") : "重要")
        return Button {
            do { try store.editTodo(id: item.id, epoch: epoch, change: .toggleImportance) }
            catch { errorMessage = error.localizedDescription }
        } label: {
            chip(Image(systemName: important ? "flag.fill" : "flag"), label, tint: TodoTheme.important, active: important)
        }.buttonStyle(.plain)
            .help(important ? "取消重要任务" : "设为重要任务")
            .accessibilityLabel("\(important ? "取消重要任务" : "设为重要任务")：\(item.text)")
    }

    private var trailingActions: some View {
        let showTagButton = hovering || choosingTags
        return HStack(spacing: 0) {
            iconButton("number", help: "添加或修改绑定标签") { choosingTags = true }
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
            iconButton(hasLinkedNote ? "doc.text.fill" : "square.and.pencil",
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
        .opacity(hovering ? 1 : 0.5)
    }

    private func iconButton(_ systemImage: String, help: String, tint: Color? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10.5, weight: .medium))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundColor(tint ?? .secondary).help(help)
    }

    /// 不用横向 ScrollView：每行一个嵌套滚动视图会让列表滚动掉帧。放不下的标签在右侧截断。
    private var tagStrip: some View {
        HStack(spacing: 4) {
            ForEach(tags) { tag in
                Button { inspectingTag = tag } label: {
                    Text("#\(tag.name)").font(.system(size: 10, weight: .medium))
                        .foregroundColor(TodoTheme.accent)
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(TodoTheme.accent.opacity(0.09)))
                        .contentShape(Capsule())
                }.buttonStyle(.plain).help("#\(tag.name)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
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
            .background(prominent ? AnyShapeStyle(TodoTheme.gradient) : AnyShapeStyle(TodoTheme.accent.opacity(0.1)),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
    }
}
