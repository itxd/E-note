import SwiftUI
import AppKit

// MARK: - Deck 根视图
// 布局(right dock):扇出 = 右缘一条 tab 宽的面板,tab 垂直叠瓦;
// 展开 = [gutter tab][便签][剩余 tab 列],便签垂直方向与自己的 tab 居中对齐。

struct DeckRootView: View {
    @ObservedObject var deck: DeckController
    @ObservedObject var store = NoteStore.shared

    var body: some View {
        GeometryReader { geo in
            if deck.state == .rest {
                PillView(deck: deck)
                    .frame(width: deck.pillWidth, height: geo.size.height)
                    .position(x: deck.edgeRight ? geo.size.width - deck.pillWidth / 2 : deck.pillWidth / 2,
                              y: geo.size.height / 2)
            } else {
                fanContent(size: geo.size)
            }
        }
        .contentShape(Rectangle())
        .onHover { deck.setHovering($0) }
    }

    @ViewBuilder
    private func fanContent(size: CGSize) -> some View {
        let notes = NoteStore.shared.visibleNotes()
        let displayed = deck.displayedCount
        let strip = deck.stripWidth
        let cardW = deck.cardWidth
        let deckH = deck.deckHeight
        let expandedIdx = deck.state == .expanded ? deck.expandedIndex : nil
        let anchorX = deck.edgeRight ? size.width - cardW / 2 : cardW / 2

        // tabs:垂直叠瓦(叠放靠 ZStack 声明顺序,后声明的在上,不显式 zIndex)
        ZStack {
            ForEach(0..<displayed, id: \.self) { index in
                if index < notes.count, index != expandedIdx {
                    NoteTab(deck: deck, note: notes[index], index: index)
                        .frame(width: cardW, height: deckH)
                        .position(x: anchorX, y: strip * CGFloat(index) + deckH / 2)
                        .opacity(deck.revealedCount > index ? 1 : 0)
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)

        // 底部控件:列表按钮(打开 All Notes,带溢出数量)+ 圆形 + 新建(扇出/展开都在)
        VStack(spacing: 8) {
            ListButton(count: deck.overflowCount)
            PlusButton(action: { deck.newNote() })
        }
        .position(x: anchorX, y: deck.stackHeight + 10 + deck.controlsHeight / 2)

        // 展开的便签 + gutter tab
        if let idx = expandedIdx, idx < notes.count {
            expandedGroup(note: notes[idx], size: size)
        }
    }

    @ViewBuilder
    private func expandedGroup(note: NoteRecord, size: CGSize) -> some View {
        // gutter 是一个小 tag:与便签同高(不再是全 deckHeight 的整条),窄条宽度
        let gutter = GutterTab(deck: deck, note: note)
            .frame(width: deck.cardWidth, height: deck.noteHeight)
        let card = Group {
            if note.isTodoList {
                TodoListView(onClose: { deck.collapse() })
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.16), radius: 6, y: 2)
            } else {
                NoteCardView(deck: deck, note: note)
            }
        }
        .id(LocalProfile.epoch.uuidString + note.id.uuidString)
        .frame(width: deck.noteWidth, height: deck.noteHeight)
        let groupWidth = deck.cardWidth * 2 + deck.noteWidth
        let centerX = deck.edgeRight ? size.width - groupWidth / 2 : groupWidth / 2
        if deck.edgeRight {
            HStack(spacing: 0) { gutter; card }
                .frame(width: groupWidth, height: deck.noteHeight)
                .position(x: centerX, y: deck.expandedCenterY)
        } else {
            HStack(spacing: 0) { card; gutter }
                .frame(width: groupWidth, height: deck.noteHeight)
                .position(x: centerX, y: deck.expandedCenterY)
        }
    }
}

// MARK: - 唤醒感应区(Hide deck 时用)

struct TriggerView: View {
    @ObservedObject var deck: DeckController

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { deck.wakeFromTrigger() }
            }
    }
}

// MARK: - Rest:pill(深色半透明细条 + 每个便签一条便签纸颜色小横条)

struct PillView: View {
    @ObservedObject var deck: DeckController
    @ObservedObject var store = NoteStore.shared

    var notes: [NoteRecord] { Array(store.visibleNotes().prefix(8)) }

    var body: some View {
        let count = max(notes.count, 1)
        let barHeight = max(4, (deck.pillHeight - 6 - CGFloat(count) * 3) / CGFloat(count))
        return ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(0.55))
            VStack(spacing: 3) {
                ForEach(notes) { note in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(NoteColor.named(note.colorName).tab.opacity(0.85))
                        .frame(height: barHeight)
                }
            }
            .padding(3)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { deck.showFan() }
        }
        .onTapGesture { deck.showFan() }
        .contextMenu {
            Button("Labelled tabs(竖排标题)") { AppSettings.shared.deckStyle = "labelled" }
            Button("Colour chips(纯色块)") { AppSettings.shared.deckStyle = "chips" }
            Divider()
            Button("设置…") { AppDelegate.shared.showSettings() }
            Button("关于 E note") { AppInfo.showAbout() }
        }
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in deck.pillDragChanged(value.translation) }
                .onEnded { _ in deck.pillDragEnded() }
        )
    }
}

// MARK: - Fan:单个便签 tab

struct NoteTab: View {
    @ObservedObject var deck: DeckController
    @ObservedObject var store = NoteStore.shared
    @ObservedObject var watcher = OverdueWatcher.shared
    let note: NoteRecord
    let index: Int

    @State private var dragOffset: CGFloat = 0

    private var isCovered: Bool {
        guard index + 1 < deck.displayedCount else { return false }
        return ((index + 1)..<deck.displayedCount).contains { next in
            deck.state != .expanded || next != deck.expandedIndex
        }
    }

    var body: some View {
        TabLook(deck: deck, note: note,
                titleHeight: isCovered ? deck.stripWidth : deck.deckHeight,
                verticalTitle: !isCovered)
            .overlay(
                // overdue 角标:小红点
                Group {
                    if watcher.isOverdue(note.id) || watcher.isDueSoon(note.id) {
                        Circle()
                            .fill(watcher.isOverdue(note.id) ? Color.red : Color.orange)
                            .frame(width: 5, height: 5)
                            .padding(2)
                            .shadow(color: .white.opacity(0.6), radius: 0.5)
                    }
                },
                alignment: .topTrailing
            )
            .offset(y: dragOffset)
            .contentShape(Rectangle())
            .onHover { hovering in deck.hoverTab(note, hovering: hovering) }
            .onTapGesture { deck.toggleExpand(note) }
            .gesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { value in
                        guard deck.state == .fan else { return }
                        dragOffset = value.translation.height
                    }
                    .onEnded { value in
                        guard deck.state == .fan else { dragOffset = 0; return }
                        let step = max(deck.stripWidth, 1)
                        let dest = index + Int((value.translation.height / step).rounded())
                        store.moveVisible(from: index, to: dest)
                        dragOffset = 0
                    }
            )
    }
}

// MARK: - tab 外观(扇出 tab 和 gutter tab 共用)

struct TabLook: View {
    @ObservedObject var deck: DeckController
    @ObservedObject var settings = AppSettings.shared
    let note: NoteRecord
    let titleHeight: CGFloat
    let verticalTitle: Bool

    private var color: NoteColor { NoteColor.named(note.colorName) }

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                .fill(color.tab)
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            if settings.deckStyle != "chips" {
                // 被覆盖的标签只使用顶部露出的横条；完整标签使用纵向空间。
                TabTitle(title: note.isTodoList && !verticalTitle ? "TODO" : note.title,
                         isPinned: note.isPinned && !note.isTodoList,
                         width: deck.cardWidth, height: titleHeight,
                         vertical: verticalTitle, scale: settings.deckScale,
                         fontSize: note.isTodoList && !verticalTitle ? 8 : 11)
                    .foregroundColor(color.labelColor)
            }
        }
    }
}

// MARK: - 展开便签左侧的 gutter tab(两侧虚线分隔)

struct GutterTab: View {
    @ObservedObject var deck: DeckController
    let note: NoteRecord

    var body: some View {
        TabLook(deck: deck, note: note,
                titleHeight: deck.noteHeight, verticalTitle: true)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { deck.toggleEnlarged() }
            .help(deck.enlarged ? "双击恢复原大小" : "双击放大至 2.5 倍")
            .overlay(
                DashedLine()
                    .stroke(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .frame(width: 1),
                alignment: .leading
            )
            .overlay(
                DashedLine()
                    .stroke(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .frame(width: 1),
                alignment: .trailing
            )
    }
}

// MARK: - 底部控件:列表按钮(进 All Notes)、圆形 + 按钮

struct ListButton: View {
    /// 超出 3 张的数量;0 = 不显示数量
    let count: Int

    var body: some View {
        Button(action: {
            NotificationCenter.default.post(name: .notyOpenLibrary, object: nil, userInfo: ["tab": 0])
        }) {
            HStack(spacing: 4) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 11, weight: .semibold))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.45), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct PlusButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 26, height: 26)
                .background(Color.black.opacity(0.35), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Expanded:展开的便签卡片(header / 正文 / footer)

struct NoteCardView: View {
    @ObservedObject var deck: DeckController
    let note: NoteRecord
    @ObservedObject var store = NoteStore.shared
    @ObservedObject var find = FindState.shared
    @ObservedObject var taskEdit = TaskEditState.shared
    @State private var now = Date()

    private var color: NoteColor { NoteColor.named(note.colorName) }
    private var primaryColor: Color { color.isDark ? .white : Color.black.opacity(0.82) }
    private var secondaryColor: Color { primaryColor.opacity(0.65) }
    private var pillBackground: Color { color.isDark ? .white.opacity(0.16) : .black.opacity(0.1) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            if deck.showFind {
                findBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            NoteEditor(noteID: note.id, deck: deck)
            Divider().opacity(0.4)
            footer
        }
        .frame(width: deck.noteWidth, height: deck.noteHeight)
        .foregroundColor(primaryColor)
        .background(color.paper)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            if let todoID = note.linkedTodoID, let task = NoteStore.shared.todo(identifier: todoID.uuidString) {
                Text(task.code).font(.system(.caption, design: .monospaced)).foregroundColor(TodoTheme.accent)
            }
            Text(note.title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("已保存 · \(relativeTimeString(from: note.modifiedAt, to: now))")
                .font(.system(size: 11))
                .foregroundColor(secondaryColor)
            Button(action: archiveNote) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundColor(secondaryColor)
            .help("归档(⇧⌘A)")
            Button(action: toggleFind) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundColor(deck.showFind ? primaryColor : secondaryColor)
            .help("查找(⌘F)")
            Button(action: insertTask) {
                Image(systemName: "checklist")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundColor(secondaryColor)
            .help("插入待办(⌘T)")
            if taskEdit.activeNoteID == note.id && taskEdit.caretOnTaskLine {
                Button(action: pickDueDate) {
                    Image(systemName: "alarm")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundColor(primaryColor)
                .help("设置到期时间")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func insertTask() {
        EditorRegistry.shared.editor(for: note.id)?.toggleTaskLine()
    }

    private func pickDueDate() {
        guard let coordinator = EditorRegistry.shared.editor(for: note.id),
              let window = coordinator.textView?.window else { return }
        let current = coordinator.currentLineDueDate()
        let anchor = window.convertToScreen(coordinator.textView?.frame ?? .zero)
        DueDatePickerController.shared.show(anchor: anchor, initial: current) { date in
            coordinator.setDueDate(date)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                ForEach(NoteColor.all) { c in
                    Circle()
                        .fill(c.tab)
                        .frame(width: 12, height: 12)
                        .overlay(
                            Circle()
                                .stroke(Color.white, lineWidth: 2)
                                .shadow(color: .black.opacity(0.3), radius: 1)
                                .opacity(c.name == note.colorName ? 1 : 0)
                        )
                        .onTapGesture {
                            store.setColor(id: note.id, colorName: c.name)
                        }
                }
            }
            Spacer(minLength: 4)
            pillButton("归档", action: archiveNote)
            pillButton("删除", action: deleteNote)
            pillButton("关闭") { deck.collapse() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func pillButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(pillBackground, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: 动作

    private func archiveNote() {
        store.setArchived(id: note.id, archived: true)
        deck.collapse()
    }

    private func deleteNote() {
        if let deleted = store.delete(id: note.id) {
            UndoToastController.shared.show(deletedTitle: deleted.title)
        }
        deck.collapse()
    }

    private func toggleFind() {
        if deck.showFind {
            deck.showFind = false
            FindState.shared.isVisible = false
            EditorRegistry.shared.editor(for: note.id)?.clearHighlights()
        } else {
            deck.showFind = true
            FindState.shared.isVisible = true
        }
    }

    // MARK: 查找栏

    private var findBar: some View {
        HStack(spacing: 6) {
            TextField("查找…", text: $find.query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
                .onChange(of: find.query) { query in
                    EditorRegistry.shared.editor(for: note.id)?.performSearch(query)
                }
            Text(find.total > 0 ? "\(find.current)/\(find.total)" : "无匹配")
                .font(.system(size: 11))
                .foregroundColor(secondaryColor)
                .frame(width: 48, alignment: .leading)
            Button("上一个") { EditorRegistry.shared.editor(for: note.id)?.prevMatch() }
            Button("下一个") { EditorRegistry.shared.editor(for: note.id)?.nextMatch() }
            Spacer(minLength: 0)
            Button(action: { EditorRegistry.shared.editor(for: note.id)?.closeFind() }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(secondaryColor)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial)
    }
}

struct DashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}

extension Notification.Name {
    static let notyOpenLibrary = Notification.Name("NotyOpenLibrary")
}
