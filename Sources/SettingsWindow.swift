import SwiftUI
import AppKit

// MARK: - 设置窗口(⌘,)

final class SettingsWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = "E note 设置"
        window.minSize = NSSize(width: 620, height: 460)
        window.contentView = NSHostingView(rootView: SettingsView())
        window.center()
        self.init(window: window)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var store = NoteStore.shared
    @State private var tab = 0
    @ObservedObject var api = LocalAPIServer.shared
    @ObservedObject var updater = AppUpdater.shared

    var body: some View {
        TabView(selection: $tab) {
            AccountSettingsView()
                .tabItem { Label("账号", systemImage: "icloud") }
                .tag(6)
            general
                .tabItem { Label("通用", systemImage: "gearshape") }
                .tag(0)
            appearance
                .tabItem { Label("外观", systemImage: "paintbrush") }
                .tag(1)
            shortcuts
                .tabItem { Label("快捷键", systemImage: "keyboard") }
                .tag(2)
            data
                .tabItem { Label("数据", systemImage: "externaldrive") }
                .tag(3)
            integration
                .tabItem { Label("API", systemImage: "terminal") }
                .tag(5)
            about
                .tabItem { Label("关于", systemImage: "info.circle") }
                .tag(4)
        }
        .padding(16)
        .frame(width: 640, height: 480)
    }

    // MARK: 通用

    private var about: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
                .accessibilityLabel("E note 应用图标")
            Text(AppInfo.name)
                .font(.system(size: 28, weight: .semibold))
            Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")")
                .foregroundColor(.secondary)
            Text("屏幕边缘，随手记下。")
                .foregroundColor(.secondary)
            Text("作者：\(AppInfo.author)")
                .padding(.top, 12)
            Link(AppInfo.email, destination: URL(string: "mailto:\(AppInfo.email)")!)
                .textSelection(.enabled)
            Toggle("自动检查更新（每天一次）", isOn: Binding(
                get: { updater.automaticallyChecks }, set: { updater.automaticallyChecks = $0 }
            ))
            .disabled(!updater.available)
            HStack {
                Button("检查更新…") { updater.checkForUpdates() }
                Link("发布记录", destination: URL(string: "https://github.com/itxd/E-note/releases")!)
            }
            if let error = updater.configurationError {
                Text(error).font(.caption).foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var general: some View {
        Form {
            GroupBox("Deck 行为") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Deck 尺寸")
                        HStack {
                            Slider(value: $settings.deckScale, in: 0.7...1.8)
                                .frame(width: 180)
                            Text("\(Int(settings.deckScale * 100))%")
                                .frame(width: 40)
                                .foregroundColor(.secondary)
                        }
                    }
                    GridRow {
                        Text("显示器")
                        Picker("", selection: $settings.showOnAllDisplays) {
                            Text("仅主显示器").tag(false)
                            Text("所有显示器").tag(true)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }
                    GridRow {
                        Text("停靠边缘")
                        Picker("", selection: $settings.dockEdge) {
                            Text("屏幕右侧").tag("right")
                            Text("屏幕左侧").tag("left")
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }
                }
                .padding(6)
                Divider().padding(.vertical, 2)
                Toggle("保持 Deck 展开(扇出作为静止态)", isOn: $settings.keepDeckOpen)
                Toggle("在全屏 App 上方显示", isOn: $settings.showOverFullscreen)
                Toggle("静止时完全隐藏 Deck(pill 位置仍可唤醒)", isOn: $settings.hideDeck)
                Toggle("悬停在标签上直接打开便签", isOn: $settings.openOnHover)
            }
            GroupBox(NoteRecord.todoListTitle) {
                Toggle("常驻待办清单（固定在顶部）", isOn: $settings.todoListEnabled)
                Toggle("临近到期时探出标签提醒", isOn: $settings.todoReminderEnabled)
                Picker("提前提醒", selection: $settings.todoReminderMinutes) {
                    ForEach([1, 5, 10, 15, 30, 60, 120], id: \.self) { minutes in
                        Text("\(minutes) 分钟").tag(minutes)
                    }
                }
                .disabled(!settings.todoReminderEnabled)
                Text("只收集待办，关闭常驻后仍可在便签库查看。临近到期显示橙点，逾期显示红点；只探出标签，不抢焦点。")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            GroupBox("启动") {
                Toggle("登录时启动 E note", isOn: Binding(
                    get: { AppSettings.shared.loginItemEnabled },
                    set: { LoginItems.setEnabled($0) }
                ))
                .padding(6)
            }
        }
        .formStyle(.grouped)
    }

    private var integration: some View {
        Form {
            GroupBox("本地 API") {
                Toggle("允许本机程序和 AI 调用", isOn: $settings.apiEnabled)
                Text(api.status).font(.system(size: 11)).foregroundColor(.secondary)
                Text("http://127.0.0.1:\(LocalAPIServer.port)")
                    .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                Text("仅本机可访问，使用访问令牌验证。E note 运行时可创建便签、添加或完成待办。")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                HStack {
                    Button("复制访问令牌") { api.copyToken() }
                        .disabled(!settings.apiEnabled)
                    Button("打开 API 配置目录") {
                        NSWorkspace.shared.open(AppPaths.supportDir)
                    }
                }
                Text("调用配置：api.json（包含地址与令牌，仅当前用户可读）")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: 外观

    private var appearance: some View {
        Form {
            GroupBox("Deck 样式") {
                Picker("标签样式", selection: $settings.deckStyle) {
                    Text("Labelled tabs(竖排标题)").tag("labelled")
                    Text("Colour chips(纯色块)").tag("chips")
                }
                .pickerStyle(.radioGroup)
                Text("也可以在 pill 上右键切换。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            GroupBox("编辑器") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("字号")
                        HStack {
                            Slider(value: $settings.editorFontSize, in: 10...22)
                                .frame(width: 180)
                            Text("\(Int(settings.editorFontSize))pt")
                                .frame(width: 40)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(6)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: 快捷键

    private var shortcuts: some View {
        Form {
            GroupBox("全局快捷键(固定,不可修改)") {
                shortcutRow("⌥⌘N", "新建便签")
                shortcutRow("⇧⌘Space", "快速捕捉")
                shortcutRow("⌥⌘A", "全部便签")
                shortcutRow("⌥⌘L", "归档")
            }
            GroupBox("便签内快捷键") {
                shortcutRow("Esc", "收起便签")
                shortcutRow("⌘.", "循环换色")
                shortcutRow("⌘T", "当前行转为任务 / 取消任务")
                shortcutRow("Return", "任务列表内延续;空任务上结束列表")
                shortcutRow("⌘⌫", "删除便签(10 秒内可撤销)")
                shortcutRow("⇧⌘A", "归档便签")
                shortcutRow("⌘P", "置顶(pinned)")
                shortcutRow("⌃+ / ⌃−", "调整字号")
                shortcutRow("⌘F", "查找")
            }
        }
        .formStyle(.grouped)
    }

    private func shortcutRow(_ keys: String, _ desc: String) -> some View {
        HStack {
            Text(keys)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(width: 110, alignment: .leading)
            Text(desc)
                .font(.system(size: 12))
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
    }

    // MARK: 数据

    private var data: some View {
        Form {
            GroupBox("导出") {
                HStack(spacing: 10) {
                    Button("导出 Markdown(每便签一个 .md)") { ExportImport.exportToDirectory(format: .markdown) }
                    Button("导出纯文本(每便签一个 .txt)") { ExportImport.exportToDirectory(format: .plainText) }
                }
                HStack(spacing: 10) {
                    Button("导出合并单文件(.md)") { ExportImport.exportMerged(format: .markdown) }
                    Button("导出合并单文件(.txt)") { ExportImport.exportMerged(format: .plainText) }
                }
                Text("任务行导出为标准 - [ ] / - [x] 语法,导入时自动读回。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            GroupBox("导入") {
                Button("导入 .md / .txt 为便签…") { ExportImport.importFiles() }
                Text("当前共 \(store.notes.count) 条便签(含归档与已删除)。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            GroupBox("存储") {
                Text("数据目录:\(AppPaths.supportDir.path)")
                    .font(.system(size: 11))
                    .textSelection(.enabled)
                Text("notes.json 中正文为 AES-GCM 256 加密,密钥存于 note.key(0600 权限),标题/颜色/时间戳为明文。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
