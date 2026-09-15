import Foundation
import CoreServices

// MARK: - 设置(UserDefaults,立即生效)

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = ProcessInfo.processInfo.environment["ENOTE_SETTINGS_SUITE"]
        .flatMap { UserDefaults(suiteName: $0) } ?? UserDefaults.standard

    var todoListEnabled: Bool {
        get { d.object(forKey: "todoListEnabled") as? Bool ?? true }
        set {
            d.set(newValue, forKey: "todoListEnabled")
            NoteStore.shared.ensureTodoList()
            OverdueWatcher.shared.refreshSoon()
            objectWillChange.send()
        }
    }

    var todoReminderEnabled: Bool {
        get { d.object(forKey: "todoReminderEnabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "todoReminderEnabled"); OverdueWatcher.shared.refreshSoon(); objectWillChange.send() }
    }

    var todoReminderMinutes: Int {
        get { max(1, min(120, d.object(forKey: "todoReminderMinutes") as? Int ?? 10)) }
        set { d.set(max(1, min(120, newValue)), forKey: "todoReminderMinutes"); OverdueWatcher.shared.refreshSoon(); objectWillChange.send() }
    }

    var apiEnabled: Bool {
        get { d.object(forKey: "apiEnabled") as? Bool ?? true }
        set {
            d.set(newValue, forKey: "apiEnabled")
            LocalAPIServer.shared.configure()
            objectWillChange.send()
        }
    }

    private func get(_ key: String, default def: Double) -> Double {
        let v = d.double(forKey: key)
        return v == 0 ? def : v
    }

    var deckScale: Double {
        get { min(1.8, max(0.7, get("deckScale", default: 1.0))) }
        set { d.set(newValue, forKey: "deckScale"); objectWillChange.send() }
    }

    var editorFontSize: Double {
        get { min(22, max(10, get("editorFontSize", default: 13))) }
        set { d.set(newValue, forKey: "editorFontSize"); objectWillChange.send() }
    }

    var keepDeckOpen: Bool {
        get { d.bool(forKey: "keepDeckOpen") }
        set { d.set(newValue, forKey: "keepDeckOpen"); objectWillChange.send() }
    }

    var showOverFullscreen: Bool {
        get { d.bool(forKey: "showOverFullscreen") }
        set { d.set(newValue, forKey: "showOverFullscreen"); objectWillChange.send() }
    }

    var hideDeck: Bool {
        get { d.bool(forKey: "hideDeck") }
        set { d.set(newValue, forKey: "hideDeck"); objectWillChange.send() }
    }

    var openOnHover: Bool {
        get { d.bool(forKey: "openOnHover") }
        set { d.set(newValue, forKey: "openOnHover"); objectWillChange.send() }
    }

    var showOnAllDisplays: Bool {
        get { d.bool(forKey: "showOnAllDisplays") }
        set { d.set(newValue, forKey: "showOnAllDisplays"); objectWillChange.send() }
    }

    /// "right" / "left"
    var dockEdge: String {
        get { d.string(forKey: "dockEdge") ?? "right" }
        set { d.set(newValue, forKey: "dockEdge"); objectWillChange.send() }
    }

    /// 相对屏幕中心的纵向偏移(AppKit 坐标,向上为正)
    var dockOffsetY: Double {
        get { d.double(forKey: "dockOffsetY") }
        set { d.set(newValue, forKey: "dockOffsetY"); objectWillChange.send() }
    }

    /// "labelled" / "chips"
    var deckStyle: String {
        get { d.string(forKey: "deckStyle") ?? "labelled" }
        set { d.set(newValue, forKey: "deckStyle"); objectWillChange.send() }
    }

    /// 新建便签计数(默认色深蓝/天蓝交替用)
    var noteCreationCount: Int {
        get { d.integer(forKey: "noteCreationCount") }
        set { d.set(newValue, forKey: "noteCreationCount"); objectWillChange.send() }
    }

    var loginItemEnabled: Bool {
        get { d.bool(forKey: "loginItemEnabled") }
        set { d.set(newValue, forKey: "loginItemEnabled"); objectWillChange.send() }
    }
}

// MARK: - 登录项(LSSharedFileList,对 ad-hoc 签名友好;SMAppService 对 ad-hoc 签名不可靠,不用)

enum LoginItems {
    private static var list: LSSharedFileList? = {
        LSSharedFileListCreate(nil, kLSSharedFileListSessionLoginItems.takeUnretainedValue(), nil)?.takeRetainedValue()
    }()

    private static func snapshotItems() -> [LSSharedFileListItem] {
        guard let list = list else { return [] }
        var seed = UInt32(0)
        guard let cfItems = LSSharedFileListCopySnapshot(list, &seed)?.takeRetainedValue() as? [LSSharedFileListItem] else { return [] }
        return cfItems
    }

    private static func resolve(_ item: LSSharedFileListItem) -> URL? {
        LSSharedFileListItemCopyResolvedURL(item, 0, nil)?.takeRetainedValue() as URL?
    }

    static func isEnabled() -> Bool {
        let appURL = Bundle.main.bundleURL
        for item in snapshotItems() {
            if let url = resolve(item), url == appURL { return true }
        }
        return false
    }

    static func setEnabled(_ enabled: Bool) {
        guard let list = list else { return }
        let appURL = Bundle.main.bundleURL as CFURL
        if enabled {
            if !isEnabled() {
                LSSharedFileListInsertItemURL(list, kLSSharedFileListItemBeforeFirst.takeUnretainedValue(), nil, nil, appURL, nil, nil)
            }
        } else {
            for item in snapshotItems() {
                if let url = resolve(item), url == Bundle.main.bundleURL {
                    LSSharedFileListItemRemove(list, item)
                }
            }
        }
        AppSettings.shared.loginItemEnabled = isEnabled()
    }
}
