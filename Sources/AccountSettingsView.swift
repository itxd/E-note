import SwiftUI

// 作者：韦冬 2220285589@qq.com
struct AccountSettingsView: View {
    @ObservedObject private var cloud = CloudSync.shared
    @State private var server = CloudServerDefaults.server
    @State private var pin = CloudServerDefaults.pin
    @State private var username = ""
    @State private var password = ""
    @State private var invite = ""
    @State private var registering = false
    @State private var importOffline = true
    @State private var error = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: cloud.signedIn ? "checkmark.icloud.fill" : "icloud")
                        .font(.system(size: 32)).foregroundStyle(TodoTheme.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(cloud.signedIn ? cloud.username : "随时记录，多端接续").font(.title3.bold())
                        Text(cloud.status).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if cloud.busy { ProgressView().controlSize(.small) }
                }
                if cloud.signedIn {
                    HStack {
                        Button { run { try await cloud.sync() } } label: { Label("立即同步", systemImage: "arrow.triangle.2.circlepath") }
                        Button("退出账号") { run { try await cloud.logout() } }
                        Spacer()
                    }.disabled(cloud.busy)
                    Text("离线时照常保存，联网后自动同步。退出后切回独立的本机便签；账号便签保存在本机，下次登录可继续。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(cloud.conflicts) { conflict in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(conflict.local.payload["title"]?.string ?? conflict.local.payload["text"]?.string ?? conflict.local.payload["name"]?.string ?? "同步冲突").fontWeight(.semibold)
                                Text("同时修改：" + conflict.fields.joined(separator: "、")).font(.caption)
                                HStack(alignment: .top) {
                                    preview("本机", entity: conflict.local)
                                    preview("云端", entity: conflict.remote)
                                }
                                HStack {
                                    Button("保留两份") { resolve(conflict.id, "both") }
                                    Button("使用本机") { resolve(conflict.id, "local") }
                                    Button("使用云端") { resolve(conflict.id, "remote") }
                                }.disabled(cloud.busy)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } else {
                    Text("不登录也可完整使用本机便签。登录后，便签、待办和执行记录在你的电脑之间自动同步。")
                        .font(.callout).foregroundStyle(.secondary)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow { Text("服务器"); TextField("https://…", text: $server) }
                        GridRow { Text("账号"); TextField("账号或邮箱", text: $username) }
                        GridRow { Text("密码"); SecureField("至少 10 位", text: $password) }
                        if registering { GridRow { Text("邀请码"); SecureField("服务器邀请码", text: $invite) } }
                    }
                    .textFieldStyle(.roundedBorder)
                    DisclosureGroup("私有服务器证书") {
                        TextField("SHA-256 证书指纹；公共 HTTPS 证书留空", text: $pin).font(.caption.monospaced())
                    }
                    Toggle("首次登录时，将本机便签复制到此账号", isOn: $importOffline)
                    Text("已有账号数据不会重新导入；本机原始便签会保留。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(registering ? "注册并同步" : "登录并同步") {
                            run {
                                try await cloud.login(server: server, pin: pin, username: username, password: password,
                                                      registrationCode: registering ? invite : nil, importOffline: importOffline)
                                password = ""; invite = ""
                            }
                        }.buttonStyle(AccountButtonStyle(primary: true))
                        Button(registering ? "已有账号，去登录" : "创建账号") { registering.toggle() }
                    }.disabled(cloud.busy)
                }
                if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            }.buttonStyle(AccountButtonStyle())
            .padding(16)
            .onChange(of: server) { value in
                pin = value == CloudServerDefaults.server ? CloudServerDefaults.pin : ""
            }
        }
    }
    private func preview(_ title: String, entity: CloudEntity) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption.bold())
            Text(entity.deleted ? "已删除" : (entity.payload["body"]?.string ?? entity.payload["text"]?.string ?? ""))
                .font(.caption).lineLimit(8).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func resolve(_ id: String, _ choice: String) {
        do { try cloud.resolve(id: id, choice: choice); error = "" } catch { self.error = error.localizedDescription }
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        error = ""
        Task { @MainActor in do { try await operation() } catch { self.error = error.localizedDescription } }
    }
}

private struct AccountButtonStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(primary ? .white : TodoTheme.accent)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(primary ? TodoTheme.accent : TodoTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
