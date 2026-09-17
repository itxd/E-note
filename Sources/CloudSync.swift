import Foundation
import CryptoKit
import Security

// 作者：韦冬 2220285589@qq.com
private struct CloudAccount: Codable {
    var accountID: String
    var username: String
    var token: String
    var server: String
    var certificateSHA256: String
}
private struct CloudState: Codable {
    var account: CloudAccount
    var snapshot = CloudSnapshot()
    var conflicts: [SyncConflict] = []
    var lastSync: Date? = nil
}
private struct SyncJournal: Codable {
    var state: CloudState
    var entities: [CloudEntity]
}
struct CloudFailure: Error, LocalizedError {
    var status: Int
    var message: String
    var errorDescription: String? { message }
}

/// TLS uses system trust by default, or an explicitly configured leaf-certificate fingerprint.
/// Redirects are refused, including redirects that might disclose the bearer token.
private final class CloudTransport: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    let base: URL
    let pin: String
    init(base: URL, pin: String) { self.base = base; self.pin = pin }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == base.host, !pin.isEmpty else {
            completionHandler(.performDefaultHandling, nil); return
        }
        guard let trust = challenge.protectionSpace.serverTrust,
              let certificate = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        let hash = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
        guard hash == pin else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        // Treat the pinned certificate as a private anchor; still validate hostname and validity.
        SecTrustSetAnchorCertificates(trust, [certificate] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        guard SecTrustEvaluateWithError(trust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func request(_ method: String, path: String, body: [String: Any], token: String) async throws -> Data {
        var request = URLRequest(url: base.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if method != "GET" { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw CloudFailure(status: (response as? HTTPURLResponse)?.statusCode ?? 502,
                               message: value?["error"] as? String ?? "云端请求失败")
        }
        return data
    }
}

final class CloudSync: ObservableObject {
    static let shared = CloudSync()
    @Published private(set) var status = "单机使用 · 未登录"
    @Published private(set) var busy = false
    @Published private(set) var username = ""
    @Published private(set) var conflicts: [SyncConflict] = []
    @Published private(set) var workflows: [[String: JSONValue]] = []
    @Published private(set) var lastSync: Date?
    private var state: CloudState?
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var scheduled: DispatchWorkItem?
    private var generation = UUID()
    private var loadingError: String?
    private var file: URL { LocalProfile.directory.appendingPathComponent("cloud-state.enc") }
    private var journalFile: URL { LocalProfile.directory.appendingPathComponent("sync-journal.enc") }
    var signedIn: Bool { state != nil }
    var deviceID: String {
        let url = AppPaths.supportDir.appendingPathComponent("device-id")
        if let id = try? String(contentsOf: url, encoding: .utf8), UUID(uuidString: id) != nil { return id }
        let id = UUID().uuidString
        _ = NoteStoreIO.atomicWrite(Data(id.utf8), to: url)
        return id
    }
    private init() { load() }

    private func load() {
        state = nil; loadingError = nil
        if FileManager.default.fileExists(atPath: file.path) {
            do { state = try read(CloudState.self, from: file) }
            catch { loadingError = "同步状态文件无法读取，已保留本机数据" }
        }
        publish()
    }
    private func publish() {
        username = state?.account.username ?? ""
        conflicts = state?.conflicts ?? []
        workflows = state?.snapshot.workflows ?? []
        lastSync = state?.lastSync
        status = loadingError ?? (state == nil ? "单机使用 · 未登录" : (conflicts.isEmpty ? "已登录 · 等待同步" : "有 \(conflicts.count) 条冲突待处理"))
    }
    private func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let encrypted = try String(contentsOf: url, encoding: .utf8)
        return try JSONDecoder().decode(type, from: Data(NoteCrypto.shared.open(encrypted).utf8))
    }
    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let plain = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        let sealed = NoteCrypto.shared.seal(plain)
        guard !sealed.isEmpty, NoteStoreIO.atomicWrite(Data(sealed.utf8), to: url) else { throw APIError(500, "无法保存同步状态") }
    }
    @MainActor func start() {
        do {
            if FileManager.default.fileExists(atPath: journalFile.path) {
                let journal = try read(SyncJournal.self, from: journalFile)
                try NoteStore.shared.applyCloud(journal.entities)
                try write(journal.state, to: file)
                state = journal.state
                try FileManager.default.removeItem(at: journalFile)
                publish()
            }
        } catch { loadingError = "同步恢复失败：\(error.localizedDescription)"; status = loadingError! }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.automaticSync() }
        }
        observer = NotificationCenter.default.addObserver(forName: .enoteLocalSaved, object: nil, queue: .main) { [weak self] _ in
            self?.scheduled?.cancel()
            let work = DispatchWorkItem { [weak self] in Task { @MainActor [weak self] in await self?.automaticSync() } }
            self?.scheduled = work
            DispatchQueue.main.asyncAfter(deadline: .now()+1, execute: work)
        }
        Task { await automaticSync() }
    }
    @MainActor private func automaticSync() async {
        guard state != nil, !busy, loadingError == nil, conflicts.isEmpty else { return }
        do { try await sync() } catch { status = "待同步 · \(error.localizedDescription)" }
    }

    @MainActor func login(server: String, pin: String, username: String, password: String,
                          registrationCode: String?, importOffline: Bool) async throws {
        guard !busy else { throw APIError(409, "同步正在进行，请稍后") }
        guard loadingError == nil else { throw APIError(409, loadingError!) }
        let normalized = server.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: normalized), let host = url.host,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              url.scheme == "https" || (url.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host)) else {
            throw APIError(400, "请输入 HTTPS 服务器地址（本机调试允许 HTTP）")
        }
        let fingerprint = pin.lowercased().replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard fingerprint.isEmpty || fingerprint.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw APIError(400, "证书指纹应为 64 位 SHA-256")
        }
        busy = true; defer { busy = false }
        var input: [String: Any] = ["username": username, "password": password, "deviceID": deviceID]
        if let code = registrationCode { input["registrationCode"] = code }
        let data = try await CloudTransport(base: url, pin: fingerprint).request("POST",
            path: registrationCode == nil ? "/v1/auth/login" : "/v1/auth/register", body: input, token: "")
        struct LoginResult: Decodable { var accountID: String; var username: String; var token: String }
        let result = try JSONDecoder().decode(LoginResult.self, from: data)
        let account = CloudAccount(accountID: result.accountID, username: result.username, token: result.token,
                                   server: normalized, certificateSHA256: fingerprint)
        let profile = LocalProfile.key(server: normalized, account: result.accountID)
        try NoteStore.shared.switchProfile(to: profile, importing: importOffline && LocalProfile.current == "offline")
        generation = UUID()
        load()
        guard loadingError == nil else { throw APIError(500, loadingError!) }
        var next = state ?? CloudState(account: account)
        next.account = account
        try write(next, to: file)
        state = next
        publish()
        // Sync follows after busy is released; offline saves remain available if network disappears.
        Task { @MainActor in await automaticSync() }
    }

    @MainActor func logout() async throws {
        guard !busy else { throw APIError(409, "同步正在进行，请稍后退出") }
        busy = true; defer { busy = false }
        let old = state
        // Revoke online when possible; always remove the local token. No new network work after logout.
        if let account = old?.account, let url = URL(string: account.server) {
            _ = try? await CloudTransport(base: url, pin: account.certificateSHA256).request("POST", path: "/v1/auth/logout", body: [:], token: account.token)
        }
        if var old = old { old.account.token = ""; try write(old, to: file) }
        try NoteStore.shared.switchProfile(to: "offline", importing: false)
        generation = UUID(); state = nil; loadingError = nil; publish()
    }

    @MainActor private func call(_ method: String, _ path: String, _ body: [String: Any] = [:]) async throws -> Data {
        guard let account = state?.account, !account.token.isEmpty, let url = URL(string: account.server) else {
            throw APIError(401, "请先在设置中登录云端账号")
        }
        return try await CloudTransport(base: url, pin: account.certificateSHA256).request(method, path: path, body: body, token: account.token)
    }

    @MainActor private func integrate(_ remote: CloudSnapshot) throws {
        guard var next = state else { throw APIError(401, "账号已退出") }
        guard remote.cursor >= next.snapshot.cursor else { throw APIError(409, "服务器返回旧版本，请重新同步") }
        EditorRegistry.shared.saveAll()
        guard NoteStore.shared.lastSaveSucceeded else { throw APIError(500, "本机保存失败，暂停同步") }
        let base = Dictionary(uniqueKeysWithValues: next.snapshot.entities.map { ($0.id, $0) })
        let local = Dictionary(uniqueKeysWithValues: NoteStore.shared.cloudEntities().map { ($0.id, $0) })
        let cloud = Dictionary(uniqueKeysWithValues: remote.entities.map { ($0.id, $0) })
        var merged: [CloudEntity] = [], conflicts: [SyncConflict] = []
        for id in Set(base.keys).union(local.keys).union(cloud.keys).sorted() {
            let (value, conflict) = CloudMerge.merge(base: base[id], local: local[id], remote: cloud[id])
            if let value = value { merged.append(value) }
            if let conflict = conflict { conflicts.append(conflict) }
        }
        next.snapshot = remote; next.conflicts = conflicts
        try commit(next, entities: merged)
    }

    @MainActor private func commit(_ next: CloudState, entities: [CloudEntity]) throws {
        try write(SyncJournal(state: next, entities: entities), to: journalFile)
        try NoteStore.shared.applyCloud(entities)
        try write(next, to: file)
        state = next
        try FileManager.default.removeItem(at: journalFile)
        publish()
    }

    private func changes() -> [[String: Any]] {
        guard let state = state else { return [] }
        let base = Dictionary(uniqueKeysWithValues: state.snapshot.entities.map { ($0.id, $0) })
        let local = Dictionary(uniqueKeysWithValues: NoteStore.shared.cloudEntities().map { ($0.id, $0) })
        return Set(base.keys).union(local.keys).sorted().compactMap { id in
            var value = local[id]
            if value == nil, var deleted = base[id] { deleted.deleted = true; value = deleted }
            guard let entity = value, !entity.sameContent(as: base[id]),
                  let encoded = try? JSONEncoder().encode(entity),
                  var json = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any] else { return nil }
            json["baseRevision"] = base[id]?.revision ?? 0
            return json
        }
    }

    @MainActor func sync() async throws {
        guard !busy else { throw APIError(409, "同步正在进行") }
        guard loadingError == nil else { throw APIError(500, loadingError!) }
        guard conflicts.isEmpty else { throw APIError(409, "请先处理同步冲突") }
        busy = true; status = "正在同步…"; defer { busy = false }
        do { try await syncLocked() }
        catch { status = "待同步 · \(error.localizedDescription)"; throw error }
    }
    @MainActor private func syncLocked() async throws {
        let epoch = generation
        for _ in 0..<5 {
            let data = try await call("GET", "/v1/sync")
            guard epoch == generation else { throw APIError(409, "账号已切换") }
            try integrate(JSONDecoder().decode(CloudSnapshot.self, from: data))
            guard conflicts.isEmpty else { throw APIError(409, "发现同时修改，请在账号设置中处理冲突") }
            let pending = changes()
            if pending.isEmpty {
                state?.lastSync = Date()
                if let state = state { try write(state, to: file) }
                publish(); status = "已同步 · 所有更改已保存"
                return
            }
            do {
                let response = try await call("POST", "/v1/sync", ["requestID": UUID().uuidString, "changes": Array(pending.prefix(1000))])
                // Do not apply the response against an old baseline: acknowledge only the sent fields,
                // then merge newer edits made while the request was in flight.
                let snapshot = try JSONDecoder().decode(CloudSnapshot.self, from: response)
                var acknowledged = state!.snapshot
                for json in pending.prefix(1000) {
                    let sent = try JSONDecoder().decode(CloudEntity.self, from: JSONSerialization.data(withJSONObject: json))
                    acknowledged.entities.removeAll { $0.id == sent.id }
                    acknowledged.entities.append(sent)
                }
                let previous = state!.snapshot
                state!.snapshot = acknowledged
                do { try integrate(snapshot) } catch { state!.snapshot = previous; throw error }
            } catch let failure as CloudFailure where failure.status == 409 { continue }
        }
        throw APIError(409, "其他设备持续更新，稍后会继续同步")
    }

    @MainActor func resolve(id: String, choice: String) throws {
        guard !busy, var next = state, let conflict = next.conflicts.first(where: { $0.id == id }) else {
            throw APIError(409, "冲突不存在或正在同步")
        }
        EditorRegistry.shared.saveAll()
        let current = NoteStore.shared.cloudEntities()
        let latestLocal = current.first { $0.id == id } ?? conflict.local
        var values = current.filter { $0.id != id }
        switch choice {
        case "local": values.append(latestLocal)
        case "remote": values.append(conflict.remote)
        case "both":
            values.append(conflict.remote)
            var copy = latestLocal; copy.id = UUID().uuidString; copy.revision = 0; copy.deleted = false
            if copy.kind == "note" {
                copy.payload["title"] = .string((copy.payload["title"]?.string ?? "便签") + " · 本机冲突副本")
                copy.payload["workflowID"] = .null
                copy.payload["linkedTodoID"] = .null
            }
            values.append(copy)
        default: throw APIError(400, "choice 必须为 local、remote 或 both")
        }
        next.conflicts.removeAll { $0.id == id }
        try commit(next, entities: values)
    }

    func statusJSON() -> [String: Any] {
        ["signedIn": signedIn, "username": username, "accountID": state?.account.accountID as Any? ?? NSNull(),
         "deviceID": deviceID, "server": state?.account.server as Any? ?? NSNull(),
         "cursor": state?.snapshot.cursor ?? 0, "busy": busy, "status": status,
         "conflicts": conflicts.map { ["id": $0.id, "fields": $0.fields] as [String: Any] },
         "lastSync": lastSync.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull()]
    }

    @MainActor func workflow(_ path: String, body: [String: Any]) async throws -> Any {
        let leased = ["/heartbeat", "/event", "/finish"].contains { path.hasSuffix($0) }
        guard body["requestID"] != nil else { throw APIError(400, "流程操作需要持久化 requestID，超时请使用同一编号重试") }
        if leased {
            // Lease renewal must not contend with a background pull or an unrelated note conflict.
            // It changes no local data, and remains bound to the current account epoch.
            let epoch = generation
            let data = try await call("POST", path, body)
            guard epoch == generation else { throw APIError(409, "账号已切换，停止旧任务") }
            return try JSONSerialization.jsonObject(with: data)
        }
        guard !busy, conflicts.isEmpty, loadingError == nil else { throw APIError(409, "请等待同步或处理冲突") }
        busy = true; defer { busy = false }
        try await syncLocked()
        let input = body
        // Caller-supplied cursor binds intent to the state the caller actually reviewed.
        if !leased {
            guard let cursor = input["cursor"] as? Int, cursor == state?.snapshot.cursor else {
                throw APIError(409, "状态有更新，请读取最新流程后重新确认")
            }
        }
        let data = try await call("POST", path, input)
        let value = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        if let raw = value["snapshot"], !leased {
            let snapshot = try JSONDecoder().decode(CloudSnapshot.self, from: JSONSerialization.data(withJSONObject: raw))
            try integrate(snapshot)
        }
        return value
    }
}

extension Notification.Name { static let enoteLocalSaved = Notification.Name("enoteLocalSaved") }
