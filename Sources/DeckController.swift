import AppKit
import SwiftUI
import QuartzCore

// MARK: - Deck 状态机:rest(药丸)→ fan(扇出)→ expanded(展开)
// 每张显示器一个 DeckController。

final class DeckController: NSObject, ObservableObject {
    enum State: Equatable {
        case rest
        case fan
        case expanded
    }

    let screen: NSScreen
    let panel: DeckPanel
    let triggerPanel: EdgeTriggerPanel

    @Published var state: State = .rest
    @Published var expandedID: UUID? = nil
    @Published var revealedCount: Int = 0
    @Published var enlarged = false
    @Published var showFind: Bool = false

    private var fanWork: DispatchWorkItem?
    private var idleWork: DispatchWorkItem?
    private var hoverTabWork: DispatchWorkItem?

    private var isHovering = false

    /// 是否由 TODO 提醒探出；解决后只收起自动探出的标签，不关闭用户正在看的卡片。
    private var reminderPeekActive = false

    // ⌥ 拖动 pill 的临时状态
    private var dragStartOffset: CGFloat = 0
    private var provisionalOffset: CGFloat?
    private var provisionalEdge: String?

    var settings: AppSettings { .shared }

    init(screen: NSScreen) {
        self.screen = screen
        panel = DeckPanel(contentRect: .zero,
                          styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered,
                          defer: false)
        triggerPanel = EdgeTriggerPanel(contentRect: .zero,
                                        styleMask: [.borderless, .nonactivatingPanel],
                                        backing: .buffered,
                                        defer: false)
        super.init()

        panel.contentView = FirstMouseHostingView(rootView: DeckRootView(deck: self))
        triggerPanel.contentView = FirstMouseHostingView(rootView: TriggerView(deck: self))
        for v in [panel.contentView, triggerPanel.contentView].compactMap({ $0 }) {
            v.autoresizingMask = [.width, .height]
        }
        refreshLevel()
        applyFrame(animated: false)
        updateVisibility()
        panel.orderFront(nil)
    }

    func teardown() {
        panel.orderOut(nil)
        triggerPanel.orderOut(nil)
    }

    func refreshLevel() {
        panel.level = settings.showOverFullscreen ? .statusBar : .floating
        triggerPanel.level = panel.level
    }

    // MARK: 几何(垂直叠瓦:每张 tab 高 tabHeight,第 i 张比第 i-1 张低一个 stripWidth;一次最多 3 张)

    var edgeRight: Bool { (provisionalEdge ?? settings.dockEdge) == "right" }

    var dockOffsetY: CGFloat { provisionalOffset ?? CGFloat(settings.dockOffsetY) }

    /// 单张 tab 的高度(约 120pt × 缩放)
    var deckHeight: CGFloat {
        min(max(120 * settings.deckScale, 80), screen.frame.height - 80)
    }

    /// 展开便签的尺寸
    var noteHeight: CGFloat {
        let isTodo = expandedID.flatMap { NoteStore.shared.note(id: $0) }?.isTodoList == true
        // TODO 卡片需要给筛选与输入框留空间，小尺寸下也能完整显示至少一项。
        let base = min(max((isTodo ? 340 : 300) * settings.deckScale, isTodo ? 260 : 200), screen.frame.height - 120)
        return min(base * (enlarged ? 2.5 : 1), screen.visibleFrame.height - 16)
    }

    var noteWidth: CGFloat { min(340 * settings.deckScale * (enlarged ? 2.5 : 1), screen.visibleFrame.width - cardWidth * 2) }

    func toggleEnlarged() {
        guard state == .expanded else { return }
        enlarged.toggle()
        applyFrame(animated: false)
    }
    var pillWidth: CGFloat { 12 }

    /// 每张 tab 露出的窄条高度:固定 22pt × 缩放(短标题省略显示)
    var stripWidth: CGFloat { 22 * settings.deckScale }

    var cardWidth: CGFloat {
        max(stripWidth + (settings.deckStyle == "chips" ? 8 : 14), 34)
    }

    var totalNotes: Int { NoteStore.shared.visibleNotes().count }

    /// 一次最多 3 张
    var displayedCount: Int { min(max(totalNotes, 1), 3) }

    var overflowCount: Int { max(0, totalNotes - displayedCount) }

    /// 叠瓦区高度 = 一张全高 + (n-1) 个窄条
    var stackHeight: CGFloat {
        deckHeight + stripWidth * CGFloat(max(displayedCount - 1, 0))
    }

    /// 底部控件实际高度:列表按钮(约 23)+ 间距 8 + 圆形 + 按钮 26
    var controlsHeight: CGFloat { 57 }

    /// 底部控件区:控件 + 上下各 10pt 边距
    var bottomBarHeight: CGFloat { controlsHeight + 20 }

    var expandedIndex: Int? {
        guard let id = expandedID else { return nil }
        return NoteStore.shared.visibleNotes().firstIndex { $0.id == id }
    }

    /// 展开便签中心(未钳制,相对叠瓦区顶部,与自己的 tab 平齐)
    private var rawExpandedCenterY: CGFloat {
        CGFloat(expandedIndex ?? 0) * stripWidth + deckHeight / 2
    }

    /// 展开态面板高:以钳制后的中心计算,保证整张便签都在面板内
    private var expandedPanelHeight: CGFloat {
        let needed = max(rawExpandedCenterY, noteHeight / 2 + 8) + noteHeight / 2 + 8
        return max(fanPanelHeight, needed)
    }

    /// 展开便签中心:优先与 tab 对齐;空间不足时钳制在面板内
    var expandedCenterY: CGFloat {
        let minC = noteHeight / 2 + 8
        let maxC = max(expandedPanelHeight - noteHeight / 2 - 8, minC)
        return min(max(rawExpandedCenterY, minC), maxC)
    }

    /// 扇出时面板宽度恒定 = tab 宽度
    var fanWidth: CGFloat { cardWidth }

    /// 展开:gutter tab + 便签 + 剩余 tab 列
    var expandedWidth: CGFloat { cardWidth * 2 + noteWidth }

    /// 扇出态面板总高
    var fanPanelHeight: CGFloat { stackHeight + bottomBarHeight }

    /// 收起 pill 高度 = deck 总高的 0.85
    var pillHeight: CGFloat { fanPanelHeight * 0.85 }

    var panelHeight: CGFloat {
        switch state {
        case .rest: return pillHeight
        case .fan: return fanPanelHeight
        case .expanded: return expandedPanelHeight
        }
    }

    var currentWidth: CGFloat {
        switch state {
        case .rest: return pillWidth
        case .fan: return fanWidth
        case .expanded: return expandedWidth
        }
    }

    /// deck 顶部默认贴菜单栏下方:距屏幕顶 = 菜单栏高度 + 16pt
    var topGap: CGFloat {
        (screen.frame.maxY - screen.visibleFrame.maxY) + 16
    }

    /// 面板顶边 y(AppKit 坐标):默认在菜单栏下方,dockOffsetY 向上为正
    private var restingTop: CGFloat {
        let top = screen.frame.maxY - topGap - dockOffsetY
        return min(top, screen.visibleFrame.maxY)
    }

    func frameForCurrentState() -> NSRect {
        let w = currentWidth
        let h = panelHeight
        let x = edgeRight ? screen.frame.maxX - w : screen.frame.minX
        let top = max(restingTop, screen.frame.minY + h)
        return NSRect(x: x, y: top - h, width: w, height: h)
    }

    func applyFrame(animated: Bool) {
        let frame = frameForCurrentState()
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
        let pillTop = max(restingTop, screen.frame.minY + pillHeight)
        let tFrame = NSRect(x: edgeRight ? screen.frame.maxX - pillWidth : screen.frame.minX,
                            y: pillTop - pillHeight,
                            width: pillWidth,
                            height: pillHeight)
        triggerPanel.setFrame(tFrame, display: false)
    }

    func notesDidChange() {
        if let id = expandedID, !NoteStore.shared.visibleNotes().contains(where: { $0.id == id }) {
            collapse()
        }
        if state != .rest { revealedCount = displayedCount }
        applyFrame(animated: false)
    }

    func updateVisibility() {
        let hidden = settings.hideDeck && state == .rest
        panel.alphaValue = hidden ? 0 : 1
        panel.ignoresMouseEvents = hidden
        if hidden {
            triggerPanel.orderFront(nil)
        } else {
            triggerPanel.orderOut(nil)
        }
    }

    // MARK: 状态机

    func showFan() {
        cancelFanWork()
        switch state {
        case .expanded:
            return
        case .fan:
            scheduleFanTimeout()
            return
        case .rest:
            break
        }
        withAnimation(.easeOut(duration: 0.25)) {
            state = .fan
        }
        applyFrame(animated: true)
        startStagger()
        scheduleFanTimeout()
        updateVisibility()
    }

    private func startStagger() {
        revealedCount = 0
        let n = displayedCount
        for i in 0..<n {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.045 * Double(i)) { [weak self] in
                self?.revealedCount = i + 1
            }
        }
    }

    /// 保证 tabs 可见(直接展开、未经过 fan 时 revealedCount 可能还是 0)
    private func ensureRevealed() {
        if revealedCount < displayedCount {
            revealedCount = displayedCount
        }
    }

    private func scheduleFanTimeout() {
        cancelFanWork()
        guard !settings.keepDeckOpen, !OverdueWatcher.shared.hasTodoReminder else { return }
        let work = DispatchWorkItem { [weak self] in self?.collapse() }
        fanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func scheduleIdle() {
        cancelIdleWork()
        guard let id = expandedID, let note = NoteStore.shared.note(id: id), !note.isPinned else { return }
        // overdue 便签常驻:空闲也不收起
        guard !OverdueWatcher.shared.isOverdue(id) else { return }
        let work = DispatchWorkItem { [weak self] in self?.collapse() }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
    }

    func expand(_ note: NoteRecord, focus: Bool = true) {
        if let previous = expandedID { EditorRegistry.shared.editor(for: previous)?.saveNow() }
        cancelFanWork()
        cancelIdleWork()
        showFind = false
        FindState.shared.reset()
        ensureRevealed()
        withAnimation(.easeOut(duration: 0.25)) {
            state = .expanded
            expandedID = note.id
        }
        applyFrame(animated: true)
        updateVisibility()
        if focus {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self, self.state == .expanded, self.expandedID == note.id else { return }
                self.panel.makeKey()
                EditorRegistry.shared.focus(id: note.id)
            }
        }
    }

    func toggleExpand(_ note: NoteRecord) {
        if state == .expanded && expandedID == note.id {
            collapse()
        } else {
            expand(note)
        }
    }

    func collapse() {
        cancelFanWork()
        cancelIdleWork()
        cancelHoverTabWork()
        showFind = false
        FindState.shared.reset()
        EditorRegistry.shared.editor(for: expandedID ?? UUID())?.clearHighlights()
        let target: State = settings.keepDeckOpen || OverdueWatcher.shared.hasTodoReminder ? .fan : .rest
        reminderPeekActive = OverdueWatcher.shared.hasTodoReminder
        withAnimation(.easeOut(duration: 0.2)) {
            state = target
            expandedID = nil
        }
        applyFrame(animated: true)
        if target == .fan {
            startStagger()
            scheduleFanTimeout()
        }
        updateVisibility()
    }

    /// 切换应用时保留手动打开的 TODOList；提醒只保留探出的标签。
    func hideForOtherApp() {
        if let id = expandedID,
           OverdueWatcher.shared.isOverdue(id) || (settings.todoListEnabled && NoteStore.shared.note(id: id)?.isTodoList == true) { return }
        collapse()
    }

    /// 不抢焦点，不自动展开正文；用户正在编辑其他便签时只更新提醒标记。
    func overdueDidChange() {
        guard OverdueWatcher.shared.hasTodoReminder else {
            let shouldClose = reminderPeekActive && state == .fan && !settings.keepDeckOpen && !isHovering
            reminderPeekActive = false
            if shouldClose { collapse() }
            return
        }
        if state != .expanded {
            reminderPeekActive = true
            panel.orderFront(nil)
            showFan()
        }
    }

    func wakeFromTrigger() {
        panel.orderFront(nil)
        showFan()
    }

    // MARK: 悬停

    func setHovering(_ hovering: Bool) {
        isHovering = hovering
        if hovering {
            cancelFanWork()
            cancelIdleWork()
        } else {
            cancelHoverTabWork()
            if state == .fan { scheduleFanTimeout() }
            if state == .expanded { scheduleIdle() }
        }
    }

    func hoverTab(_ note: NoteRecord, hovering: Bool) {
        cancelHoverTabWork()
        guard hovering, settings.openOnHover, state == .fan else { return }
        let work = DispatchWorkItem { [weak self] in self?.expand(note) }
        hoverTabWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func cancelFanWork() { fanWork?.cancel(); fanWork = nil }
    private func cancelIdleWork() { idleWork?.cancel(); idleWork = nil }
    private func cancelHoverTabWork() { hoverTabWork?.cancel(); hoverTabWork = nil }

    // MARK: 新建

    func newNote() {
        let note = NoteStore.shared.create()
        expand(note)
    }

    // MARK: ⌥ 拖动 pill

    func pillDragChanged(_ translation: CGSize) {
        guard NSEvent.modifierFlags.contains(.option) else { return }
        if provisionalOffset == nil {
            provisionalOffset = CGFloat(settings.dockOffsetY)
            dragStartOffset = CGFloat(settings.dockOffsetY)
        }
        provisionalOffset = dragStartOffset - translation.height
        if edgeRight, translation.width < -30 {
            provisionalEdge = "left"
        } else if !edgeRight, translation.width > 30 {
            provisionalEdge = "right"
        }
        applyFrame(animated: false)
    }

    func pillDragEnded() {
        guard provisionalOffset != nil else { return }
        // 偏移合法范围:顶边不高于可见区顶部,底边不溢出屏幕
        let anchor = screen.frame.maxY - topGap
        let lower = anchor - screen.visibleFrame.maxY
        let upper = anchor - screen.frame.minY - panelHeight
        let offset = min(max(dockOffsetY, lower), upper)
        settings.dockOffsetY = Double(offset)
        if let edge = provisionalEdge {
            settings.dockEdge = edge
        }
        provisionalOffset = nil
        provisionalEdge = nil
        applyFrame(animated: false)
    }
}
