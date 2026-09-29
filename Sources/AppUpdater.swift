import AppKit
import Combine
import Sparkle

/// Sparkle owns scheduling, signature verification, installation and relaunch.
@MainActor final class AppUpdater: NSObject, ObservableObject {
    static let shared = AppUpdater()
    @Published private(set) var available = false
    @Published private(set) var configurationError: String?
    private let driver = UpdateUserDriver()
    private var updater: SPUUpdater?

    var automaticallyChecks: Bool {
        get { updater?.automaticallyChecksForUpdates ?? true }
        set {
            objectWillChange.send()
            updater?.automaticallyChecksForUpdates = newValue
        }
    }

    func start() {
        guard updater == nil else { return }
        guard Bundle.main.object(forInfoDictionaryKey: "ENoteDevelopmentBuild") as? Bool != true else {
            configurationError = "本地开发构建不检查线上更新。"
            return
        }
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else {
            configurationError = "此构建尚未配置更新签名，请从项目发布页下载安装新版。"
            return
        }
        let instance = SPUUpdater(hostBundle: .main, applicationBundle: .main,
                                  userDriver: driver, delegate: nil)
        updater = instance
        do {
            try instance.start()
            available = true
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(checkIfDue),
                name: NSWorkspace.didWakeNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(checkIfDue),
                name: NSApplication.didBecomeActiveNotification, object: nil)
        } catch {
            configurationError = error.localizedDescription
        }
    }

    @objc func checkForUpdates() {
        guard available, let updater = updater else {
            let alert = NSAlert()
            alert.messageText = "暂时无法检查更新"
            alert.informativeText = configurationError ?? "更新器尚未启动。"
            alert.runModal()
            return
        }
        updater.checkForUpdates()
    }

    @objc private func checkIfDue() {
        guard let updater = updater, available, updater.automaticallyChecksForUpdates,
              updater.canCheckForUpdates, !updater.sessionInProgress,
              Date().timeIntervalSince(updater.lastUpdateCheckDate ?? .distantPast) >= 86400 else { return }
        updater.checkForUpdatesInBackground()
    }
}
