import SwiftUI
import AppKit

// MARK: - 查找状态(deck 的查找栏 ↔ 编辑器协调器)

final class FindState: ObservableObject {
    static let shared = FindState()
    @Published var isVisible = false
    @Published var query = ""
    @Published var current = 0
    @Published var total = 0

    func reset() {
        isVisible = false
        query = ""
        current = 0
        total = 0
    }
}

// MARK: - 任务行编辑状态(光标是否在任务行上,决定 header 是否显示"设置到期")

final class TaskEditState: ObservableObject {
    static let shared = TaskEditState()
    /// 光标所在编辑器的便签 id(无编辑器焦点时为 nil)
    @Published var activeNoteID: UUID?
    /// 光标是否处于任务行
    @Published var caretOnTaskLine = false
}

// MARK: - 编辑器注册表(SwiftUI 查找栏 / 展开后聚焦 用)

final class EditorRegistry {
    static let shared = EditorRegistry()

    private struct WeakBox { weak var value: NoteEditorCoordinator? }
    private var editors: [UUID: [WeakBox]] = [:]
    private(set) weak var active: NoteEditorCoordinator?

    func register(_ coordinator: NoteEditorCoordinator, for id: UUID) {
        editors[id, default: []].append(WeakBox(value: coordinator))
    }

    func unregister(_ coordinator: NoteEditorCoordinator, for id: UUID) {
        editors[id]?.removeAll { $0.value == nil || $0.value === coordinator }
        if active === coordinator { active = nil }
    }

    func editor(for id: UUID) -> NoteEditorCoordinator? {
        if let active = active, active.noteID == id { return active }
        return editors[id]?.compactMap { $0.value }.last
    }

    func saveAll() {
        Array(editors.values).flatMap { $0 }.forEach { $0.value?.saveNow() }
        active?.saveNow()
    }

    func markActive(_ coordinator: NoteEditorCoordinator) {
        active = coordinator
    }

    func focus(id: UUID) {
        editor(for: id)?.focus()
    }
}

// MARK: - 编辑器按键路由

protocol EditorKeyRouter: AnyObject {
    func handleKey(_ event: NSEvent) -> Bool
    func handleClick(_ event: NSEvent) -> Bool
    func didBecomeFirstResponder()
}

// MARK: - NSTextView 子类(把按键/点击转给协调器)

final class EditorTextView: NSTextView {
    weak var keyRouter: EditorKeyRouter?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        keyRouter?.didBecomeFirstResponder()
        return super.becomeFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        if let router = keyRouter, router.handleKey(event) { return }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if let router = keyRouter, router.handleClick(event) { return }
        super.mouseDown(with: event)
    }
}

// MARK: - 协调器:自动保存、快捷键、任务行、查找、样式

final class NoteEditorCoordinator: NSObject, EditorKeyRouter, NSTextViewDelegate {
    let noteID: UUID
    private let profileEpoch = LocalProfile.epoch
    weak var deck: DeckController?
    var textView: EditorTextView?

    private var saveWork: DispatchWorkItem?
    private var matches: [NSRange] = []
    private var applyingExternalBody = false
    private var hasUnsavedChanges = false

    init(noteID: UUID, deck: DeckController?) {
        self.noteID = noteID
        self.deck = deck
    }

    deinit {
        saveWork?.cancel()
    }

    // MARK: 注册 / 聚焦

    func attach(_ tv: EditorTextView) {
        textView = tv
        EditorRegistry.shared.register(self, for: noteID)
    }

    func detach() {
        saveNow()
        EditorRegistry.shared.unregister(self, for: noteID)
        textView = nil
    }

    func focus() {
        EditorRegistry.shared.markActive(self)
        textView?.window?.makeFirstResponder(textView)
    }

    func didBecomeFirstResponder() {
        EditorRegistry.shared.markActive(self)
        updateTaskEditState()
    }

    // MARK: 任务行光标状态(header"设置到期"按钮用)

    private func updateTaskEditState() {
        let state = TaskEditState.shared
        guard let tv = textView, tv.window?.firstResponder === tv else {
            if state.activeNoteID == noteID { state.activeNoteID = nil }
            state.caretOnTaskLine = false
            return
        }
        state.activeNoteID = noteID
        state.caretOnTaskLine = currentTaskLine() != nil
    }

    /// 光标所在的任务行文本(非任务行返回 nil)
    private func currentTaskLine() -> String? {
        guard let lineRange = currentLineRange else { return nil }
        let line = (textView?.string as NSString?)?.substring(with: lineRange) ?? ""
        return TaskSyntax.isTask(line) ? line : nil
    }

    /// 光标所在任务行的到期时间
    func currentLineDueDate() -> Date? {
        guard let line = currentTaskLine() else { return nil }
        return TaskSyntax.dueDate(of: line)
    }

    /// 给光标所在任务行设置/清除到期时间(写回行尾 ⏰ 标记)
    func setDueDate(_ date: Date?) {
        guard let tv = textView, let lineRange = currentLineRange else { return }
        let ns = tv.string as NSString
        let line = ns.substring(with: lineRange)
        guard TaskSyntax.isTask(line) else { return }
        let newline = TaskSyntax.settingDue(line, to: date)
        tv.setSelectedRange(lineRange)
        tv.insertText(newline, replacementRange: lineRange)
        refreshTaskStyles()
    }

    // MARK: 自动保存(250ms 防抖)

    func textDidChange(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView, tv === textView else { return }
        refreshTaskStyles()
        scheduleSave()
        updateTaskEditState()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView, tv === textView else { return }
        updateTaskEditState()
    }

    func scheduleSave() {
        hasUnsavedChanges = true
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func saveNow() {
        guard profileEpoch == LocalProfile.epoch, let tv = textView, !applyingExternalBody, hasUnsavedChanges else { return }
        saveWork?.cancel()
        hasUnsavedChanges = false
        NoteStore.shared.updateBody(id: noteID, body: tv.string)
    }

    // MARK: 外部内容变更(如快速捕捉追加)

    func syncExternalBodyIfNeeded() {
        guard profileEpoch == LocalProfile.epoch, let tv = textView, !hasUnsavedChanges else { return }
        let external = NoteStore.shared.body(id: noteID)
        guard external != tv.string else { return }
        applyingExternalBody = true
        tv.undoManager?.disableUndoRegistration()
        tv.string = external
        tv.undoManager?.enableUndoRegistration()
        applyingExternalBody = false
        refreshTaskStyles()
    }

    // MARK: 按键

    func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = mods.contains(.command)
        let shift = mods.contains(.shift)
        let ctrl = mods.contains(.control)
        let key = event.charactersIgnoringModifiers ?? ""
        let findOpen = FindState.shared.isVisible

        if ctrl, key == "+" || key == "=" {
            AppSettings.shared.editorFontSize += 1
            return true
        }
        if ctrl, key == "-" {
            AppSettings.shared.editorFontSize -= 1
            return true
        }
        if key == "\u{1b}" {
            if findOpen {
                closeFind()
            } else {
                deck?.collapse()
            }
            return true
        }
        if findOpen, event.keyCode == 36 {
            shift ? prevMatch() : nextMatch()
            return true
        }
        if cmd, !shift, key == "f" {
            if let deck = deck {
                deck.showFind = true
                FindState.shared.isVisible = true
            }
            return true
        }
        if cmd, key == "." {
            NoteStore.shared.cycleColor(id: noteID)
            return true
        }
        if cmd, !shift, !findOpen, key == "t" {
            toggleTaskLine()
            return true
        }
        if cmd, event.keyCode == 51 { // ⌘⌫
            deleteNote()
            return true
        }
        if cmd, shift, key == "a" {
            NoteStore.shared.setArchived(id: noteID, archived: true)
            deck?.collapse()
            return true
        }
        if cmd, key == "p" {
            NoteStore.shared.togglePin(id: noteID)
            return true
        }
        if !cmd, !ctrl, !shift, event.keyCode == 36 { // Return:任务列表内延续
            return handleTaskReturn()
        }
        return false
    }

    // MARK: 任务行

    private var currentLineRange: NSRange? {
        guard let tv = textView else { return nil }
        let ns = tv.string as NSString
        let caret = tv.selectedRange().location
        guard ns.length > 0 else { return NSRange(location: 0, length: 0) }
        return ns.lineRange(for: NSRange(location: min(caret, ns.length - 1), length: 0))
    }

    func toggleTaskLine() {
        guard let tv = textView, let lineRange = currentLineRange else { return }
        let ns = tv.string as NSString
        let line = ns.substring(with: lineRange)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix(TaskSyntax.openMark) || trimmed.hasPrefix(TaskSyntax.doneMark) {
            // 去掉标记
            let markerRange = markerRangeInLine(line: line, lineRange: lineRange)
            tv.setSelectedRange(markerRange)
            tv.delete(nil)
        } else {
            // 插入标记(保留行首缩进)
            let ws = line.prefix { $0 == " " || $0 == "\t" }.count
            let loc = lineRange.location + ws
            tv.setSelectedRange(NSRange(location: loc, length: 0))
            tv.insertText(TaskSyntax.openMark, replacementRange: tv.selectedRange())
        }
    }

    private func markerRangeInLine(line: String, lineRange: NSRange) -> NSRange {
        let ws = line.prefix { $0 == " " || $0 == "\t" }.count
        return NSRange(location: lineRange.location + ws, length: 1) // ☐ / ☑ 单字符
    }

    private func handleTaskReturn() -> Bool {
        guard let tv = textView, let lineRange = currentLineRange else { return false }
        let ns = tv.string as NSString
        let line = ns.substring(with: lineRange)
        guard TaskSyntax.isTask(line) else { return false }
        let content = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        if content.isEmpty {
            // 空任务上 Return:结束列表(去掉标记)
            let markerRange = markerRangeInLine(line: line, lineRange: lineRange)
            tv.setSelectedRange(markerRange)
            tv.delete(nil)
        } else {
            // 列表内延续
            tv.setSelectedRange(NSRange(location: lineRange.upperBound, length: 0))
            tv.insertText("\n" + TaskSyntax.openMark, replacementRange: tv.selectedRange())
        }
        return true
    }

    /// 点击 ☑/☐:切换完成状态
    func handleClick(_ event: NSEvent) -> Bool {
        guard let tv = textView else { return false }
        let point = tv.convert(event.locationInWindow, from: nil)
        let index = tv.characterIndexForInsertion(at: point)
        let ns = tv.string as NSString
        guard index < ns.length else { return false }
        let lineRange = ns.lineRange(for: NSRange(location: index, length: 0))
        let line = ns.substring(with: lineRange)
        guard TaskSyntax.isTask(line) else { return false }
        let ws = line.prefix { $0 == " " || $0 == "\t" }.count
        let charIndex = index - lineRange.location
        guard charIndex >= ws, charIndex <= ws + 1 else { return false } // 点在标记上
        let markerRange = NSRange(location: lineRange.location + ws, length: 1)
        let marker = ns.substring(with: markerRange)
        let replacement = marker == "☐" ? "☑" : "☐"
        tv.setSelectedRange(markerRange)
        tv.insertText(replacement, replacementRange: markerRange)
        return true
    }

    /// 已完成任务:划掉 + 变暗;到期标记:次要色小字(temporary attributes)
    func refreshTaskStyles() {
        guard let tv = textView, let layoutManager = tv.layoutManager else { return }
        let full = NSRange(location: 0, length: (tv.string as NSString).length)
        layoutManager.removeTemporaryAttribute(.strikethroughStyle, forCharacterRange: full)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        layoutManager.removeTemporaryAttribute(.font, forCharacterRange: full)
        guard full.length > 0 else { return }
        let baseColor = tv.textColor ?? NSColor.labelColor
        let dimColor = baseColor.withAlphaComponent(0.5)
        let dueColor = baseColor.withAlphaComponent(0.45)
        let baseFont = tv.font ?? NSFont.systemFont(ofSize: 13)
        let dueFont = NSFontManager.shared.convert(baseFont, toSize: max(baseFont.pointSize - 2, 9))
        let ns = tv.string as NSString
        ns.enumerateSubstrings(in: full, options: .byLines) { substring, range, _, _ in
            guard let line = substring, TaskSyntax.isTask(line) else { return }
            var rangeToStyle = range
            if rangeToStyle.length > 0, ns.substring(with: rangeToStyle).hasSuffix("\n") {
                rangeToStyle.length -= 1
            }
            guard rangeToStyle.length > 0 else { return }
            if TaskSyntax.isDone(line) {
                layoutManager.addTemporaryAttribute(.strikethroughStyle, value: 1, forCharacterRange: rangeToStyle)
                layoutManager.addTemporaryAttribute(.foregroundColor, value: dimColor, forCharacterRange: rangeToStyle)
            }
            // 行尾 ⏰ 标记:小字 + 次要色
            if let marker = TaskSyntax.dueMarkerRange(in: line) {
                let markerRange = NSRange(location: rangeToStyle.location + marker.location,
                                          length: min(marker.length, rangeToStyle.upperBound - (rangeToStyle.location + marker.location)))
                guard markerRange.length > 0 else { return }
                layoutManager.addTemporaryAttribute(.font, value: dueFont, forCharacterRange: markerRange)
                layoutManager.addTemporaryAttribute(.foregroundColor, value: dueColor, forCharacterRange: markerRange)
            }
        }
    }

    // MARK: 查找

    func performSearch(_ query: String) {
        clearHighlights()
        matches.removeAll()
        let state = FindState.shared
        state.current = 0
        state.total = 0
        guard let tv = textView, !query.isEmpty else { return }
        let ns = tv.string as NSString
        var searchRange = NSRange(location: 0, length: ns.length)
        while searchRange.length > 0, matches.count < 5000 {
            let r = ns.range(of: query, options: [.caseInsensitive], range: searchRange)
            if r.location == NSNotFound { break }
            matches.append(r)
            searchRange = NSRange(location: r.upperBound, length: ns.length - r.upperBound)
        }
        state.total = matches.count
        for r in matches {
            tv.layoutManager?.addTemporaryAttribute(.backgroundColor,
                                                    value: NSColor.systemYellow.withAlphaComponent(0.35),
                                                    forCharacterRange: r)
        }
        if !matches.isEmpty {
            selectMatch(0)
        }
    }

    func nextMatch() {
        guard !matches.isEmpty else { return }
        let state = FindState.shared
        selectMatch(state.current % matches.count)
    }

    func prevMatch() {
        guard !matches.isEmpty else { return }
        let state = FindState.shared
        selectMatch((state.current - 2 + matches.count) % matches.count)
    }

    private func selectMatch(_ index: Int) {
        guard let tv = textView, index < matches.count else { return }
        let r = matches[index]
        tv.scrollRangeToVisible(r)
        tv.setSelectedRange(r)
        FindState.shared.current = index + 1
    }

    func clearHighlights() {
        guard let tv = textView else { return }
        let full = NSRange(location: 0, length: (tv.string as NSString).length)
        tv.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        matches.removeAll()
    }

    func closeFind() {
        FindState.shared.isVisible = false
        deck?.showFind = false
        clearHighlights()
        focus()
    }

    // MARK: 删除

    private func deleteNote() {
        guard let deck = deck else { return }
        if let note = NoteStore.shared.delete(id: noteID) {
            UndoToastController.shared.show(deletedTitle: note.title)
        }
        deck.collapse()
    }
}

// MARK: - SwiftUI 包装

struct NoteEditor: View {
    let noteID: UUID
    weak var deck: DeckController?

    var body: some View {
        // NSTextView 的协调器持有便签 ID；切换便签必须重建编辑器身份。
        NoteEditorContent(noteID: noteID, deck: deck).id(LocalProfile.epoch.uuidString + noteID.uuidString)
    }
}

private struct NoteEditorContent: NSViewRepresentable {
    let noteID: UUID
    weak var deck: DeckController?

    func makeCoordinator() -> NoteEditorCoordinator {
        NoteEditorCoordinator(noteID: noteID, deck: deck)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.borderType = .noBorder

        let tv = EditorTextView(frame: .zero)
        tv.keyRouter = coordinator
        tv.delegate = coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.importsGraphics = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.textContainerInset = NSSize(width: 12, height: 12)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.autoresizingMask = [.width]
        tv.font = NSFont.systemFont(ofSize: AppSettings.shared.editorFontSize)

        let body = NoteStore.shared.body(id: noteID)
        tv.undoManager?.disableUndoRegistration()
        tv.string = body
        tv.undoManager?.enableUndoRegistration()

        scroll.documentView = tv
        coordinator.attach(tv)
        applyTextColor(to: tv, coordinator: coordinator)
        coordinator.refreshTaskStyles()
        return scroll
    }

    /// 纸面为深色时正文用白字
    private func applyTextColor(to tv: EditorTextView, coordinator: NoteEditorCoordinator) {
        let noteColor = NoteColor.named(NoteStore.shared.note(id: noteID)?.colorName ?? NoteColor.all[0].name)
        let target: NSColor = noteColor.isDark ? .white : NSColor(srgbRed: 0.18, green: 0.18, blue: 0.20, alpha: 1)
        if tv.textColor != target {
            tv.textColor = target
            tv.insertionPointColor = target
            coordinator.refreshTaskStyles()
        }
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        if let tv = scroll.documentView as? EditorTextView {
            let fontSize = AppSettings.shared.editorFontSize
            if abs(Double(tv.font?.pointSize ?? CGFloat(fontSize)) - fontSize) > 0.1 {
                tv.font = NSFont.systemFont(ofSize: fontSize)
            }
            applyTextColor(to: tv, coordinator: coordinator)
            coordinator.syncExternalBodyIfNeeded()
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: NoteEditorCoordinator) {
        coordinator.detach()
    }
}

// MARK: - 到期时间选择面板(header ⏰ 按钮弹出)

final class DueDatePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class DueDatePickerController {
    static let shared = DueDatePickerController()
    private var panel: DueDatePanel?

    /// anchor: 触发按钮附近的屏幕坐标(按钮 convertToScreen 的 frame)
    func show(anchor: NSRect, initial: Date?, onConfirm: @escaping (Date?) -> Void) {
        close()
        let size = NSSize(width: 280, height: 96)
        let x = min(max(anchor.midX - size.width / 2, 8),
                    (NSScreen.main?.visibleFrame.maxX ?? 2000) - size.width - 8)
        let yBelow = anchor.minY - size.height - 6
        let rect = NSRect(x: x,
                          y: max(yBelow, (NSScreen.main?.visibleFrame.minY ?? 0) + 8),
                          width: size.width,
                          height: size.height)
        let p = DueDatePanel(contentRect: rect,
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered,
                             defer: false)
        p.isFloatingPanel = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.hidesOnDeactivate = false

        let view = DueDatePickerView(initial: initial,
                                     onConfirm: { date in
                                         onConfirm(date)
                                         self.close()
                                     },
                                     onClear: {
                                         onConfirm(nil)
                                         self.close()
                                     },
                                     onCancel: { self.close() })
        p.contentView = NSHostingView(rootView: view)
        panel = p
        p.orderFrontRegardless()
        p.makeKey()
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

struct DueDatePickerView: View {
    @State private var date: Date
    let onConfirm: (Date) -> Void
    let onClear: () -> Void
    let onCancel: () -> Void

    init(initial: Date?, onConfirm: @escaping (Date) -> Void, onClear: @escaping () -> Void, onCancel: @escaping () -> Void) {
        _date = State(initialValue: initial ?? Date().addingTimeInterval(3600))
        self.onConfirm = onConfirm
        self.onClear = onClear
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "alarm")
                    .foregroundColor(.secondary)
                DatePicker("", selection: $date)
                    .datePickerStyle(.compact)
                    .labelsHidden()
            }
            HStack(spacing: 10) {
                Button("清除") { onClear() }
                Spacer()
                Button("取消") { onCancel() }
                Button("确定") { onConfirm(date) }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(radius: 8)
    }
}
