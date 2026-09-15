import AppKit
import SwiftUI

// MARK: - Deck 面板
// 注意(noty README 里明示的坑):
// 1. borderless nonactivating panel 默认 canBecomeKey = false,展开的便签收不到键盘,必须覆盖。
// 2. 视图默认 acceptsFirstMouse = false,第一张 tab 的点击会被吞去激活 panel,必须覆盖为 true
//    (acceptsFirstMouse(for:) 是 NSView 的方法,在 hosting view 上覆盖)。

final class DeckPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var isExcludedFromWindowsMenu: Bool {
        get { true }
        set { _ = newValue }
    }

    override init(contentRect: NSRect,
                  styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType,
                  defer flag: Bool) {
        super.init(contentRect: contentRect,
                   styleMask: style,
                   backing: backingStoreType,
                   defer: flag)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
    }
}

// MARK: - 边缘唤醒面板(Hide deck 时,静止的 deck 完全隐藏,只留下这块透明感应区)

final class EdgeTriggerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var isExcludedFromWindowsMenu: Bool {
        get { true }
        set { _ = newValue }
    }

    override init(contentRect: NSRect,
                  styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType,
                  defer flag: Bool) {
        super.init(contentRect: contentRect,
                   styleMask: style,
                   backing: backingStoreType,
                   defer: flag)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
    }
}

// MARK: - HostingView 基类:第一张点击不吞掉(直接响应,不先激活窗口)

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
