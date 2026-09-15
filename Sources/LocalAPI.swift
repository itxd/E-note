import AppKit
import Foundation
import Darwin

// 作者：韦冬 2220285589@qq.com
// 小型、单请求 HTTP/1.1 服务；仅 loopback，所有数据操作都在主线程。
final class LocalAPIServer: ObservableObject {
    static let shared = LocalAPIServer()
    static let port = UInt16(ProcessInfo.processInfo.environment["ENOTE_API_PORT"] ?? "") ?? 49178
    @Published private(set) var status = "API 未启动"
    private var listener: DispatchSourceRead?
    private var clients: [UUID: APIConnection] = [:]
    private var token = ""
    private var ownsConfiguration = false
    private var configURL: URL { AppPaths.supportDir.appendingPathComponent("api.json") }

    func configure() {
        guard AppSettings.shared.apiEnabled else { stop(); return }
        guard listener == nil else { return }
        do {
            let tokenURL = AppPaths.supportDir.appendingPathComponent("api-token")
            if FileManager.default.fileExists(atPath: tokenURL.path) {
                token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                guard token.count >= 32 else { throw APIError(500, "访问令牌文件无效") }
            } else {
                token = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                guard NoteStoreIO.atomicWrite(Data(token.utf8), to: tokenURL) else { throw APIError(500, "无法保存访问令牌") }
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw APIError(500, "无法创建 socket") }
            var installed = false
            defer { if !installed { Darwin.close(fd) } }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout.size(ofValue: one)))
            guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw APIError(500, "无法配置 socket") }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = Self.port.bigEndian
            inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, Darwin.listen(fd, 32) == 0 else {
                throw APIError(500, "端口 \(Self.port) 无法监听：\(String(cString: strerror(errno)))")
            }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            source.setCancelHandler { Darwin.close(fd) }
            source.setEventHandler { [weak self] in
                guard let self = self else { return }
                while true {
                    let clientFD = Darwin.accept(fd, nil, nil)
                    if clientFD < 0 {
                        if errno == EINTR { continue }
                        return
                    }
                    guard self.clients.count < 32, fcntl(clientFD, F_SETFL, O_NONBLOCK) == 0 else {
                        Darwin.close(clientFD); continue
                    }
                    var noSignal: Int32 = 1
                    setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
                    let id = UUID()
                    let client = APIConnection(fd: clientFD, token: self.token, route: LocalAPIRouter.handle) { [weak self] in
                        self?.clients[id] = nil
                    }
                    self.clients[id] = client
                    client.start()
                }
            }
            listener = source
            installed = true
            source.resume()
            let config: [String: Any] = ["baseURL": "http://127.0.0.1:\(Self.port)", "token": token]
            let configData = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted])
            guard NoteStoreIO.atomicWrite(configData, to: configURL) else { throw APIError(500, "无法写入 api.json") }
            ownsConfiguration = true
            status = "运行中 · 仅本机 · 需要访问令牌"
        } catch {
            listener?.cancel()
            listener = nil
            status = "API 启动失败：\(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        Array(clients.values).forEach { $0.close() }
        clients.removeAll()
        if ownsConfiguration { try? FileManager.default.removeItem(at: configURL) }
        ownsConfiguration = false
        status = "API 已关闭"
    }

    func copyToken() {
        guard !token.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(token, forType: .string)
    }
}

struct APIError: Error, LocalizedError {
    let status: Int
    let message: String
    init(_ status: Int, _ message: String) { self.status = status; self.message = message }
    var errorDescription: String? { message }
}

private final class APIConnection {
    let fd: Int32
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var readingSuspended = false
    private var output = Data()
    private var sent = 0
    let token: String
    let route: (String, String, Data) throws -> (Int, Any)
    let finished: () -> Void
    private var buffer = Data()
    private var closed = false
    private var timeout: DispatchWorkItem?
    private let maxBody = 1_048_576

    init(fd: Int32, token: String,
         route: @escaping (String, String, Data) throws -> (Int, Any), finished: @escaping () -> Void) {
        self.fd = fd; self.token = token; self.route = route; self.finished = finished
    }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.receive() }
        let socketFD = fd
        source.setCancelHandler { Darwin.close(socketFD) }
        readSource = source
        source.resume()
        let timeout = DispatchWorkItem { [weak self] in self?.close() }
        self.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
    }

    func close() {
        guard !closed else { return }
        closed = true
        timeout?.cancel()
        writeSource?.cancel()
        if readingSuspended { readSource?.resume(); readingSuspended = false }
        readSource?.cancel()
        finished()
    }

    private func receive() {
        guard !closed, !readingSuspended else { return }
        var bytes = [UInt8](repeating: 0, count: 65536)
        while !closed && !readingSuspended {
            let count = Darwin.recv(fd, &bytes, bytes.count, 0)
            if count < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { close() }
                return
            }
            if count == 0 { close(); return }
            buffer.append(contentsOf: bytes.prefix(count))
            do {
                if try process() { return }
            } catch let error as APIError {
                send(error.status, ["error": error.message])
            } catch {
                send(500, ["error": "内部错误"])
            }
        }
    }

    private func process() throws -> Bool {
        guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > 16384 { throw APIError(431, "请求头过大") }
            return false
        }
        guard separator.lowerBound <= 16384,
              let header = String(data: buffer[..<separator.lowerBound], encoding: .utf8) else { throw APIError(400, "无效请求头") }
        let lines = header.components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ")
        guard request.count == 3, request[2] == "HTTP/1.1" || request[2] == "HTTP/1.0" else { throw APIError(400, "无效 HTTP 请求") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw APIError(400, "无效请求头") }
            let name = line[..<colon].lowercased()
            guard headers[name] == nil else { throw APIError(400, "重复请求头") }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["authorization"] == "Bearer \(token)" else { throw APIError(401, "需要有效的 Bearer 访问令牌") }
        // 不为网页开放 CORS；拒绝浏览器来源与不受支持的传输编码。
        guard headers["origin"] == nil else { throw APIError(403, "不接受网页跨域调用") }
        guard headers["transfer-encoding"] == nil else { throw APIError(400, "请使用 Content-Length，不支持分块编码") }
        guard let length = Int(headers["content-length"] ?? "0"), length >= 0 else { throw APIError(400, "无效 Content-Length") }
        guard length <= maxBody else { throw APIError(413, "请求体不能超过 1 MiB") }
        let method = String(request[0])
        if method == "POST" || method == "PATCH" {
            guard headers["content-type"]?.lowercased().hasPrefix("application/json") == true else { throw APIError(415, "需要 application/json") }
        }
        let end = separator.upperBound + length
        guard buffer.count >= end else { return false }
        guard buffer.count == end else { throw APIError(400, "每个连接只接受一个请求") }
        let body = Data(buffer[separator.upperBound..<end])
        let path = String(request[1])
        if path.hasPrefix("/v1/sync") || path.hasPrefix("/v1/account/") || path.hasPrefix("/v1/workflows") {
            readingSuspended = true
            readSource?.suspend()
            timeout?.cancel()
            let timer = DispatchWorkItem { [weak self] in self?.close() }
            timeout = timer
            DispatchQueue.main.asyncAfter(deadline: .now()+120, execute: timer)
            Task { @MainActor [weak self] in
                do { self?.send(200, try await CloudAPIRouter.handle(method, path, body)) }
                catch let error as APIError { self?.send(error.status, ["error": error.message]) }
                catch let error as CloudFailure { self?.send(error.status, ["error": error.message]) }
                catch { self?.send(502, ["error": error.localizedDescription]) }
            }
            return true
        }
        let (status, response) = try route(method, path, body)
        send(status, response)
        return true
    }

    private func send(_ status: Int, _ value: Any) {
        guard !closed else { return }
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("{}".utf8)
        let reason = status < 400 ? "OK" : "Error"
        var response = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(data.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".utf8)
        response.append(data)
        output = response
        if !readingSuspended { readingSuspended = true; readSource?.suspend() }
        drainOutput()
    }

    private func drainOutput() {
        guard !closed else { return }
        while sent < output.count {
            let count = output.withUnsafeBytes { buffer in
                Darwin.send(fd, buffer.baseAddress!.advanced(by: sent), buffer.count - sent, 0)
            }
            if count < 0 {
                if errno == EINTR { continue }
                guard errno == EAGAIN || errno == EWOULDBLOCK else { close(); return }
                if writeSource == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: .main)
                    source.setEventHandler { [weak self] in self?.drainOutput() }
                    writeSource = source
                    source.resume()
                }
                return
            }
            guard count > 0 else { close(); return }
            sent += count
        }
        close()
    }
}

enum LocalAPIRouter {
    static func handle(_ method: String, _ path: String, _ data: Data) throws -> (Int, Any) {
        let store = NoteStore.shared
        if method == "GET", path == "/v1/health" { return (200, ["app": "E note", "apiVersion": 2]) }
        if method == "GET", path == "/v1/notes" {
            return (200, ["notes": store.libraryNotes().map(noteJSON)])
        }
        if method == "GET", path == "/v1/notes/all" {
            return (200, ["notes": store.notes.filter { !$0.isTodoList }.map(noteJSON)])
        }
        if path.hasPrefix("/v1/notes/") {
            let parts = path.dropFirst("/v1/notes/".count).split(separator: "/")
            guard let first = parts.first, let id = UUID(uuidString: String(first)),
                  let note = store.note(id: id), !note.isTodoList else { throw APIError(404, "便签不存在") }
            if method == "GET", parts.count == 1 { return (200, ["note": noteJSON(note)]) }
            if method == "DELETE", parts.count == 1 {
                return (200, ["note": noteJSON(try store.mutateAPINote(id: id, action: "delete"))])
            }
            if method == "POST", parts.count == 2, parts[1] == "restore" {
                return (200, ["note": noteJSON(try store.mutateAPINote(id: id, action: "restore"))])
            }
            if method == "PATCH", parts.count == 1 {
                let json = try object(data)
                guard !json.isEmpty, Set(json.keys).isSubset(of: ["body", "title", "isPinned", "isArchived"]) else { throw APIError(400, "修改字段无效") }
                func boolean(_ key: String) throws -> Bool? {
                    guard let value = json[key] else { return nil }
                    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw APIError(400, "需要布尔值") }
                    return number.boolValue
                }
                let body = try json["body"].map { try text($0, name: "body", max: 200000) }
                let title = try json["title"].map { try text($0, name: "title", max: 40) }
                let updated = try store.mutateAPINote(id: id, body: body, title: title,
                    pinned: boolean("isPinned"), archived: boolean("isArchived"))
                return (200, ["note": noteJSON(updated)])
            }
        }
        if method == "DELETE", path.hasPrefix("/v1/tags/") {
            guard let id = UUID(uuidString: String(path.dropFirst("/v1/tags/".count))) else { throw APIError(400, "标签 ID 无效") }
            try store.deleteTag(id: id)
            return (200, ["deleted": true])
        }
        if method == "DELETE", path.hasPrefix("/v1/todos/") {
            guard let item = store.todo(identifier: String(path.dropFirst("/v1/todos/".count))) else { throw APIError(404, "待办不存在") }
            guard item.canDelete else { throw APIError(409, "只能删除已完成或已归档的待办") }
            guard store.deleteTodo(id: item.id) else { throw APIError(500, "删除失败") }
            return (200, ["deleted": true])
        }
        if method == "GET", path == "/v1/tags" {
            return (200, ["tags": store.tags().map(tagJSON)])
        }
        if method == "GET", path.hasPrefix("/v1/tags/") {
            guard let id = UUID(uuidString: String(path.dropFirst("/v1/tags/".count))),
                  let tag = store.tags().first(where: { $0.id == id }) else { throw APIError(404, "标签不存在") }
            return (200, ["tag": tagJSON(tag)])
        }
        if (method == "POST" && path == "/v1/tags") || (method == "PATCH" && path.hasPrefix("/v1/tags/")) {
            let json = try object(data)
            var tag = TodoTag()
            if method == "PATCH" {
                guard let id = UUID(uuidString: String(path.dropFirst("/v1/tags/".count))),
                      let existing = store.tags().first(where: { $0.id == id }) else { throw APIError(404, "标签不存在") }
                tag = existing
            }
            if json["name"] != nil || method == "POST" { tag.name = try text(json["name"], name: "name", max: 80) }
            if let type = json["type"] {
                guard let value = type as? String, ["项目", "版本", "其他"].contains(value) else { throw APIError(400, "标签类型无效") }
                tag.type = value
            }
            if let details = json["details"] {
                guard let value = details as? String, value.count <= 20000 else { throw APIError(400, "标签说明最多 20000 字符") }
                tag.details = value
            }
            if let link = json["link"] {
                guard let value = link as? String, value.count <= 2000 else { throw APIError(400, "标签链接最多 2000 字符") }
                tag.link = value
            }
            store.saveTag(tag)
            try checkSaved()
            return (method == "POST" ? 201 : 200, ["tag": tagJSON(store.tags().first { $0.id == tag.id }!)])
        }
        if method == "GET", path == "/v1/todos" {
            return (200, ["enabled": AppSettings.shared.todoListEnabled,
                          "noteID": store.todoList?.id.uuidString as Any? ?? NSNull(),
                          "items": store.todos().map(todoJSON)] as [String: Any])
        }
        if method == "POST", path == "/v1/notes" {
            let json = try object(data)
            let body = try text(json["body"], name: "body", max: 200000)
            let title = try json["title"].map { try text($0, name: "title", max: 40) }
            let note = store.create(body: title.map { $0 + "\n" + body } ?? body)
            try checkSaved()
            return (201, ["note": noteJSON(note)])
        }
        if method == "POST", path == "/v1/todos" {
            let json = try object(data)
            let inputs: [[String: Any]]
            if let raw = json["items"] {
                guard let array = raw as? [[String: Any]], !array.isEmpty, array.count <= 100 else { throw APIError(400, "items 必须包含 1–100 个待办") }
                inputs = array
            } else { inputs = [json] }
            let items = try inputs.map { try apply($0, to: nil) }
            let created = store.addTodos(items)
            try checkSaved()
            return (201, ["noteID": store.todoList!.id.uuidString, "items": created.map(todoJSON)] as [String: Any])
        }
        if (method == "PATCH" || method == "GET"), path.hasPrefix("/v1/todos/") {
            let identifier = String(path.dropFirst("/v1/todos/".count))
            guard let existing = store.todo(identifier: identifier) else { throw APIError(404, "待办不存在") }
            if method == "GET" { return (200, ["item": todoJSON(existing)]) }
            let item = try apply(object(data), to: existing)
            store.updateTodo(item)
            try checkSaved()
            return (200, ["item": todoJSON(store.todo(identifier: identifier)!)])
        }
        throw APIError(404, "接口不存在")
    }

    private static func checkSaved() throws {
        guard NoteStore.shared.lastSaveSucceeded else { throw APIError(500, "保存失败；请检查数据目录，查询现有数据后再决定是否重试") }
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw APIError(400, "需要有效的 JSON 对象") }
        return json
    }

    private static func text(_ value: Any?, name: String, max: Int) throws -> String {
        guard let value = value as? String else { throw APIError(400, "\(name) 必须是字符串") }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= max else { throw APIError(400, "\(name) 不能为空，最多 \(max) 个字符") }
        return trimmed
    }

    private static func apply(_ json: [String: Any], to existing: TodoItem?) throws -> TodoItem {
        guard json["id"] == nil, json["number"] == nil, json["code"] == nil else {
            throw APIError(400, "id、number、code 由系统分配，不能修改")
        }
        var item = existing ?? TodoItem(text: "")
        if json["text"] != nil || existing == nil { item.text = try text(json["text"], name: "text", max: 10000) }
        if let category = json["category"] { item.category = try text(category, name: "category", max: 80) }
        if let priority = json["priority"] {
            guard let value = priority as? String, ["normal", "high"].contains(value) else { throw APIError(400, "priority 只能是 normal 或 high") }
            item.priority = value
        }
        if let completed = json["completed"] {
            guard let number = completed as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw APIError(400, "completed 必须是布尔值") }
            item.completed = number.boolValue
        }
        if let ids = json["tagIDs"] {
            guard let values = ids as? [String], values.count <= 100,
                  values.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw APIError(400, "tagIDs 必须为 UUID 数组") }
            let parsed = values.compactMap(UUID.init(uuidString:))
            guard Set(parsed).isSubset(of: Set(NoteStore.shared.tags().map { $0.id })) else { throw APIError(400, "标签不存在") }
            item.tagIDs = Array(Set(parsed)).sorted { $0.uuidString < $1.uuidString }
        }
        if let archived = json["archived"] {
            guard let value = archived as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw APIError(400, "archived 必须是布尔值") }
            item.archivedAt = value.boolValue ? Date() : nil
            if !value.boolValue { item.archiveRestoredAt = Date() }
        }
        if let due = json["dueAt"] {
            if due is NSNull { item.dueAt = nil }
            else {
                let formatter = ISO8601DateFormatter()
                let value = due as? String ?? ""
                var date = formatter.date(from: value)
                if date == nil { formatter.formatOptions.insert(.withFractionalSeconds); date = formatter.date(from: value) }
                guard let date = date else { throw APIError(400, "dueAt 必须是带时区的 ISO 8601 时间或 null") }
                item.dueAt = date
            }
        }
        return item
    }

    static func tagJSON(_ tag: TodoTag) -> [String: Any] {
        ["id": tag.id.uuidString, "name": tag.name, "type": tag.type, "details": tag.details, "link": tag.link,
         "modifiedAt": tag.modifiedAt.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull()]
    }

    static func todoJSON(_ item: TodoItem) -> [String: Any] {
        ["id": item.id.uuidString, "number": item.number as Any? ?? NSNull(), "code": item.code,
         "text": item.text, "category": item.category,
         "priority": item.priority, "completed": item.completed,
         "tagIDs": (item.tagIDs ?? []).map { $0.uuidString }, "archived": item.isArchived,
         "completedAt": item.completedAt.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull(),
         "archivedAt": item.archivedAt.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull(),
         "dueAt": item.dueAt.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull()]
    }

    static func noteJSON(_ note: NoteRecord) -> [String: Any] {
        ["id": note.id.uuidString, "title": note.title, "body": NoteStore.shared.body(of: note),
         "isArchived": note.isArchived, "deletedAt": note.deletedAt.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull(),
         "kind": note.isTodoList ? "todoList" : "note", "isPinned": note.isPinned,
         "linkedTodoID": note.linkedTodoID?.uuidString as Any? ?? NSNull(),
         "workflowID": note.workflowID?.uuidString as Any? ?? NSNull()]
    }
}
