import AppKit
import SwiftUI
import Combine

// MARK: - 装配:menu、快捷键、deck 管理、全局事件

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate!

    private var decks: [DeckController] = []
    private var library: LibraryWindowController?
    private var settingsWC: SettingsWindowController?
    private var cancellables = Set<AnyCancellable>()
    private var rebuildWork: DispatchWorkItem?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = NoteStore.shared
        LocalAPIServer.shared.configure()
        CloudSync.shared.start()

        buildMenu()
        installHotKeys()
        installFindKeyMonitor()
        installObservers()
        rebuildDecks()
        AppUpdater.shared.start()

        // overdue 扫描(30s)与已删除 30 天自动清除(启动时 + 每 6 小时)
        OverdueWatcher.shared.start()
        DeletedNotesMaintenance.run()

        // 演示/截图用:NOTY_DEMO_STATE=fan|expanded 直接打开对应状态
        if let demo = ProcessInfo.processInfo.environment["NOTY_DEMO_STATE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self, let deck = self.mainDeck() else { return }
                deck.panel.orderFront(nil)
                if demo == "expanded", let first = NoteStore.shared.visibleNotes().first {
                    deck.expand(first)
                } else {
                    deck.showFan()
                }
            }
        }

        // 右键 pill 切换 deck 样式(通过自定义 event 注入,由 PillView 处理)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(openLibrary(_:)),
                                               name: .notyOpenLibrary,
                                               object: nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard NoteStore.shared.saveAllBeforeTermination() else {
            let alert = NSAlert()
            alert.messageText = "便签尚未保存，已取消退出"
            alert.informativeText = "请检查磁盘空间和数据目录权限后重试。"
            alert.runModal()
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 关闭时也保存(自动保存早已落盘,这里兜底)
        EditorRegistry.shared.saveAll()
        LocalAPIServer.shared.stop()
    }

    // MARK: - Deck 管理

    func rebuildDecks() {
        decks.forEach { $0.teardown() }
        decks.removeAll()
        let screens = AppSettings.shared.showOnAllDisplays ? NSScreen.screens : [NSScreen.main ?? NSScreen.screens[0]]
        for screen in screens {
            decks.append(DeckController(screen: screen))
        }
        decks.forEach { $0.overdueDidChange() }
    }

    private func scheduleRebuild() {
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuildDecks() }
        rebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func openLinkedNote(_ id: UUID) {
        guard let note = NoteStore.shared.note(id: id), let deck = mainDeck() else { return }
        deck.panel.orderFront(nil)
        deck.expand(note)
    }

    private func mainDeck() -> DeckController? {
        decks.first
    }

    // MARK: - 菜单(让 ⌘C/⌘V/⌘Z 等 key equivalent 能经 responder chain 分发)

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "E note")
        let aboutItem = appMenu.addItem(withTitle: "关于 E note", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        let updateItem = appMenu.addItem(withTitle: "检查更新…", action: #selector(AppUpdater.checkForUpdates), keyEquivalent: "")
        updateItem.target = AppUpdater.shared
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 E note", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出 E note", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        func editItemAdd(_ title: String, _ key: String, _ action: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: key)
            item.action = NSSelectorFromString(action)
            editMenu.addItem(item)
        }
        editItemAdd("撤销", "z", "undo:")
        editItemAdd("重做", "Z", "redo:")
        editMenu.addItem(.separator())
        editItemAdd("剪切", "x", "cut:")
        editItemAdd("复制", "c", "copy:")
        editItemAdd("粘贴", "v", "paste:")
        editItemAdd("删除", "\u{8}", "delete:")
        editMenu.addItem(.separator())
        editItemAdd("全选", "a", "selectAll:")
        editItem.submenu = editMenu

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "全部便签", action: #selector(openAllNotes), keyEquivalent: "")
        windowMenu.addItem(withTitle: "归档", action: #selector(openArchive), keyEquivalent: "")
        windowItem.submenu = windowMenu

        mainMenu.addItem(appItem)
        mainMenu.addItem(editItem)
        mainMenu.addItem(windowItem)
        NSApp.mainMenu = mainMenu
    }

    // MARK: - 全局快捷键

    private func installHotKeys() {
        let center = HotKeyCenter.shared
        center.install()
        center.registerDefaults(
            newNote: { [weak self] in self?.newNote() },
            quickCapture: { QuickCaptureController.shared.toggle() },
            allNotes: { [weak self] in self?.openAllNotes() },
            archive: { [weak self] in self?.openArchive() }
        )
    }

    private func newNote() {
        let note = NoteStore.shared.create()
        if let deck = mainDeck() {
            deck.panel.orderFront(nil)
            deck.expand(note)
        }
    }

    // MARK: - 查找栏的 Enter / ⇧Enter / Esc(焦点在 SwiftUI 查找输入框时编辑器收不到 keyDown)

    private func installFindKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let find = FindState.shared
            guard find.isVisible else { return event }
            if event.keyCode == 36 { // Return
                if event.modifierFlags.contains(.shift) {
                    EditorRegistry.shared.active?.prevMatch()
                } else {
                    EditorRegistry.shared.active?.nextMatch()
                }
                return nil
            }
            if event.keyCode == 53 { // Esc
                EditorRegistry.shared.active?.closeFind()
                return nil
            }
            return event
        }
    }

    // MARK: - 全局事件

    private func installObservers() {
        // 点击其他 app:整组消失;快速捕捉框也随之关闭
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(otherAppActivated),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(otherAppActivated),
            name: NSApplication.didResignActiveNotification,
            object: nil)
        // 显示器变化
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(rebuildDecksDirect),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
        // 设置变更(几何相关):重建 deck
        AppSettings.shared.objectWillChange
            .sink { [weak self] _ in self?.scheduleRebuild() }
            .store(in: &cancellables)
        // 外部 API / 捕捉新增便签时同步面板尺寸，不重建或打断当前编辑器。
        NoteStore.shared.$notes
            .map { $0.map { $0.id } }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.decks.forEach { $0.notesDidChange() } }
            .store(in: &cancellables)
        // overdue 集合变化:各 deck 决定展开/常驻/恢复
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(overdueChanged),
            name: .notyOverdueChanged,
            object: nil)
    }

    @objc private func overdueChanged() {
        decks.forEach { $0.overdueDidChange() }
    }

    @objc private func otherAppActivated() {
        QuickCaptureController.shared.close()
        decks.forEach { $0.hideForOtherApp() }
    }

    @objc private func rebuildDecksDirect() {
        scheduleRebuild()
    }

    // MARK: - 窗口

    @objc private func showAbout() { AppInfo.showAbout() }

    @objc private func openAllNotes() { showLibrary(tab: 0) }
    @objc private func openArchive() { showLibrary(tab: 1) }

    @objc private func openLibrary(_ notification: Notification) {
        let tab = notification.userInfo?["tab"] as? Int ?? 0
        showLibrary(tab: tab)
    }

    private func showLibrary(tab: Int) {
        if library == nil { library = LibraryWindowController() }
        library?.show(tab: tab)
    }

    func showSettings() { openSettings() }

    @objc private func openSettings() {
        if settingsWC == nil { settingsWC = SettingsWindowController() }
        settingsWC?.show()
    }
}
