import AppKit
import SwiftUI
import Sparkle

final class UpdatePresentation: ObservableObject {
    @Published var title = "软件更新"
    @Published var detail = ""
    @Published var progress: Double?
    @Published var working = false
    @Published var primaryTitle = ""
    @Published var secondaryTitle = ""
    var primary: (() -> Void)?
    var secondary: (() -> Void)?

    func clearActions() {
        primary = nil
        secondary = nil
        primaryTitle = ""
        secondaryTitle = ""
    }
}

private struct UpdateView: View {
    @ObservedObject var model: UpdatePresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.title).font(.title2.bold())
            ScrollView { Text(model.detail).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: 150)
            if model.working {
                if let progress = model.progress {
                    ProgressView(value: progress)
                    Text("\(Int(progress * 100))%")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            HStack {
                Spacer()
                if !model.secondaryTitle.isEmpty {
                    Button(model.secondaryTitle) { model.secondary?() }
                }
                if !model.primaryTitle.isEmpty {
                    Button(model.primaryTitle) { model.primary?() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

/// Only an explicit install choice authorizes this session to restart the app.
final class UpdateUserDriver: NSObject, SPUUserDriver, NSWindowDelegate {
    private let model = UpdatePresentation()
    private var window: NSWindow?
    private var restartAuthorized = false
    private var expectedBytes: UInt64 = 0
    private var receivedBytes: UInt64 = 0
    private var retryTermination: (() -> Void)?

    private func show(focus: Bool = true) {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 468, height: 290),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "E note 更新"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: UpdateView(model: model))
            window.delegate = self
            window.center()
            self.window = window
        }
        if focus {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        } else {
            window?.orderFront(nil)
        }
    }

    private func status(_ title: String, _ detail: String, working: Bool = false) {
        model.clearActions()
        model.title = title
        model.detail = detail
        model.progress = nil
        model.working = working
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Closing may cancel or dismiss, but must never authorize an installation.
        if let dismiss = model.secondary {
            dismiss()
        } else if model.primaryTitle == "关闭", let acknowledge = model.primary {
            acknowledge()
        } else {
            sender.orderOut(nil)
        }
        return false
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        restartAuthorized = false
        status("正在检查更新", "正在获取最新版本…", working: true)
        model.secondaryTitle = "取消"
        model.secondary = { [weak self] in self?.model.clearActions(); cancellation() }
        show()
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        restartAuthorized = false
        status("发现新版本 \(appcastItem.displayVersionString)",
               "点击后将下载更新、保存全部便签，并自动安装重启。\n\n" + (appcastItem.itemDescription ?? "性能改进与问题修复。"))
        model.primaryTitle = appcastItem.isInformationOnlyUpdate ? "查看发布页" : "一键更新并重启"
        model.primary = { [weak self] in
            guard let self = self else { return }
            self.model.clearActions()
            if appcastItem.isInformationOnlyUpdate {
                if let url = appcastItem.infoURL, url.scheme == "https" { NSWorkspace.shared.open(url) }
                reply(.dismiss)
            } else {
                // An already staged update can skip showReadyToInstallAndRelaunch.
                guard self.prepareToRestart() else {
                    reply(state.stage == .installing ? .skip : .dismiss)
                    return
                }
                self.restartAuthorized = true
                reply(.install)
            }
        }
        model.secondaryTitle = "稍后"
        model.secondary = { [weak self] in self?.model.clearActions(); reply(.dismiss) }
        show(focus: state.userInitiated)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        showMessage("暂无可安装的新版本", error.localizedDescription, acknowledgement)
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        restartAuthorized = false
        showMessage("更新未完成", error.localizedDescription + "\n当前版本仍可继续使用，请稍后重试。", acknowledgement)
    }

    private func showMessage(_ title: String, _ detail: String, _ acknowledge: @escaping () -> Void) {
        status(title, detail)
        model.primaryTitle = "关闭"
        model.primary = { [weak self] in self?.model.clearActions(); acknowledge() }
        show()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedBytes = 0
        receivedBytes = 0
        status("正在下载更新", "下载完成并通过校验后，将保存便签并自动重启。", working: true)
        model.secondaryTitle = "取消更新"
        model.secondary = { [weak self] in
            self?.restartAuthorized = false
            self?.model.clearActions()
            cancellation()
        }
        show()
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedBytes = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        let (total, overflow) = receivedBytes.addingReportingOverflow(length)
        receivedBytes = overflow ? UInt64.max : total
        model.progress = expectedBytes > 0 ? min(1, Double(receivedBytes) / Double(expectedBytes)) : nil
    }

    func showDownloadDidStartExtractingUpdate() {
        status("正在准备安装", "正在校验和解压更新包…", working: true)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        model.progress = min(1, max(0, progress))
    }

    func showReadyToInstallAndRelaunch() async -> SPUUserUpdateChoice {
        guard restartAuthorized, prepareToRestart() else {
            restartAuthorized = false
            return .skip
        }
        status("正在安装更新", "便签已保存，即将自动重启。", working: true)
        return .install
    }

    private func prepareToRestart() -> Bool {
        do {
            guard NSApp.modalWindow == nil, !CloudSync.shared.busy else {
                throw NSError(domain: "EnoteUpdate", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "请先完成当前对话框或账号同步，再重试更新。"])
            }
            try NoteStore.shared.prepareForUpdate()
            return true
        } catch {
            let alert = NSAlert()
            alert.messageText = "已停止更新"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return false
        }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        status("正在安装更新", "等待 E note 安全退出并重启…", working: true)
        if !applicationTerminated {
            retryTermination = retryTerminatingApplication
            model.primaryTitle = "重试保存并重启"
            model.primary = { [weak self] in
                guard let self = self, self.prepareToRestart() else { return }
                self.retryTermination?()
            }
        }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        restartAuthorized = false
        retryTermination = nil
        model.clearActions()
        window?.orderOut(nil)
    }

    func showUpdateInFocus() { show() }
}
