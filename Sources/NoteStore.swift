import Foundation
import CryptoKit

// MARK: - 便签数据源(ObservableObject,唯一数据源)

final class NoteStore: ObservableObject {
    static let shared = NoteStore()

    @Published private(set) var notes: [NoteRecord] = []
    /// 删除后暂存,10 秒撤销窗口
    private var trash: (note: NoteRecord, index: Int)?

    private let crypto = NoteCrypto.shared
    private(set) var lastSaveSucceeded = true
    private var integrityFailed = false

    private init() {
        notes = NoteStoreIO.load()
        do { try validateEncryptedRecords(notes) }
        catch { integrityFailed = true; lastSaveSucceeded = false; return }
        guard !NoteStoreIO.loadFailed else { lastSaveSucceeded = false; return }
        ensureTodoList()
        var paletteChanged = false
        for index in notes.indices {
            let previous = notes[index].colorName
            let next = notes[index].isTodoList ? NoteColor.todo.name : NoteColor.named(previous).name
            if next != previous {
                notes[index].colorName = next
                paletteChanged = true
            }
        }
        if paletteChanged { save() }
        let existing = todos()
        if existing.contains(where: { $0.number == nil }) { saveTodos(existing) }
        lastSaveSucceeded = canSave
    }

    // MARK: 查询

    func note(id: UUID) -> NoteRecord? { notes.first { $0.id == id } }
    func libraryNotes() -> [NoteRecord] {
        let active = notes.filter { !$0.isArchived && $0.deletedAt == nil }
        return active.filter { $0.isTodoList } + active.filter { !$0.isTodoList }
    }
    func visibleNotes() -> [NoteRecord] {
        libraryNotes().filter { !$0.isTodoList || AppSettings.shared.todoListEnabled }
    }

    var todoList: NoteRecord? { notes.first { $0.isTodoList } }

    func ensureTodoList() {
        if let index = notes.firstIndex(where: { $0.isTodoList }) {
            if notes[index].title != NoteRecord.todoListTitle {
                notes[index].title = NoteRecord.todoListTitle
                save()
            }
            return
        }
        guard AppSettings.shared.todoListEnabled else { return }
        var note = NoteRecord.make(colorName: NoteColor.todo.name)
        note.kind = "todoList"
        note.title = NoteRecord.todoListTitle
        note.isPinned = true
        notes.insert(note, at: 0)
        save()
    }

    func todos() -> [TodoItem] {
        guard let sealed = todoList?.todoData,
              let data = crypto.open(sealed).data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([TodoItem].self, from: data)) ?? []
    }

    func todo(identifier: String) -> TodoItem? {
        if let uuid = UUID(uuidString: identifier) { return todos().first { $0.id == uuid } }
        let digits = identifier.uppercased().hasPrefix("T") ? String(identifier.dropFirst()) : identifier
        guard let number = Int(digits), number > 0 else { return nil }
        return todos().first { $0.number == number }
    }

    func saveTodos(_ items: [TodoItem]) {
        // API 可在常驻关闭时继续写入；只创建数据，不改变用户的显示开关。
        if todoList == nil {
            var note = NoteRecord.make(colorName: NoteColor.todo.name)
            note.kind = "todoList"
            note.title = NoteRecord.todoListTitle
            note.isPinned = true
            notes.insert(note, at: 0)
        }
        guard let i = notes.firstIndex(where: { $0.isTodoList }) else { return }
        let existing = todos()
        let numbers = Dictionary(uniqueKeysWithValues: existing.compactMap { item in item.number.map { (item.id, $0) } })
        var sequence = max(notes[i].todoSequence ?? 0, existing.compactMap { $0.number }.max() ?? 0)
        var numbered = items
        for index in numbered.indices {
            numbered[index].normalizeCompletion(previous: existing.first { $0.id == numbered[index].id })
            if let saved = numbers[numbered[index].id] {
                numbered[index].number = saved
            } else {
                sequence += 1
                numbered[index].number = sequence
            }
        }
        guard let data = try? JSONEncoder().encode(numbered),
              let json = String(data: data, encoding: .utf8) else { return }
        notes[i].todoSequence = sequence
        notes[i].todoData = crypto.seal(json)
        notes[i].body = crypto.seal(numbered.map { $0.taskLine }.joined(separator: "\n"))
        notes[i].modifiedAt = Date()
        save()
    }

    @discardableResult
    func addTodos(_ items: [TodoItem]) -> [TodoItem] {
        saveTodos(todos() + items)
        let ids = Set(items.map { $0.id })
        return todos().filter { ids.contains($0.id) }
    }

    func updateTodo(_ item: TodoItem) {
        var items = todos()
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i] = item
        saveTodos(items)
    }

    func tags() -> [TodoTag] {
        guard let sealed = todoList?.tagData else { return [] }
        return ((try? JSONDecoder().decode([TodoTag].self, from: Data(crypto.open(sealed).utf8))) ?? []).sorted {
            if $0.modifiedAt != $1.modifiedAt { return ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    func saveTag(_ input: TodoTag) {
        var tag = input
        tag.modifiedAt = Date()
        var all = tags()
        if let i = all.firstIndex(where: { $0.id == tag.id }) { all[i] = tag }
        else { all.append(tag) }
        if todoList == nil { saveTodos([]) }
        guard let i = notes.firstIndex(where: { $0.isTodoList }),
              let data = try? JSONEncoder().encode(all) else { return }
        notes[i].tagData = crypto.seal(String(decoding: data, as: UTF8.self))
        save()
    }

    func linkedNote(todoID: UUID) -> NoteRecord? {
        notes.filter { !$0.isTodoList && $0.linkedTodoID == todoID }
            .sorted {
                if ($0.deletedAt == nil) != ($1.deletedAt == nil) { return $0.deletedAt == nil }
                return $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
            }.first
    }

    /// Reuse archived/deleted records so repeated clicks cannot create another note.
    func ensureLinkedNote(todoID: UUID, epoch: UUID) throws -> NoteRecord {
        guard epoch == LocalProfile.epoch else { throw APIError(409, "账号已切换") }
        guard let item = todo(identifier: todoID.uuidString) else { throw APIError(404, "待办不存在") }
        guard canSave else { throw APIError(500, "无法保存便签") }
        var note = linkedNote(todoID: todoID) ?? NoteRecord.make(colorName: "雾紫")
        if linkedNote(todoID: todoID) == nil {
            // The same task created offline on two devices gets the same note identity.
            let bytes = Array(SHA256.hash(data: Data(("enote-linked-note:" + todoID.uuidString).utf8)).prefix(16))
            note.id = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                                 bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        }
        let previous = notes
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            note.deletedAt = nil
            note.isArchived = false
            note.modifiedAt = Date()
            notes[index] = note
        } else {
            let content = "\(item.code) · \(item.text)\n关联待办：\(item.code)\n\n"
            note.linkedTodoID = item.id
            note.title = deriveTitle(from: content)
            note.body = crypto.seal(content)
            notes.insert(note, at: 0)
        }
        save()
        guard lastSaveSucceeded else { notes = previous; throw APIError(500, "便签保存失败") }
        return note
    }

    func deleteTag(id: UUID) throws {
        guard tags().contains(where: { $0.id == id }) else { throw APIError(404, "标签不存在") }
        guard !todos().contains(where: { ($0.tagIDs ?? []).contains(id) }) else { throw APIError(409, "请先解除待办的标签绑定") }
        guard canSave, let i = notes.firstIndex(where: { $0.isTodoList }) else { throw APIError(500, "无法保存") }
        let data = try JSONEncoder().encode(tags().filter { $0.id != id })
        let previous = notes
        notes[i].tagData = crypto.seal(String(decoding: data, as: UTF8.self))
        save()
        if !lastSaveSucceeded { notes = previous; throw APIError(500, "保存失败") }
    }

    func mutateAPINote(id: UUID, body: String? = nil, title: String? = nil,
                       pinned: Bool? = nil, archived: Bool? = nil, action: String = "update") throws -> NoteRecord {
        EditorRegistry.shared.editor(for: id)?.saveNow()
        guard canSave else { throw APIError(500, "无法保存") }
        guard let i = notes.firstIndex(where: { $0.id == id && !$0.isTodoList }) else { throw APIError(404, "便签不存在") }
        var note = notes[i]
        guard action != "update" || note.deletedAt == nil else { throw APIError(409, "请先恢复已删除便签") }
        if body != nil || title != nil {
            var content = body ?? self.body(of: note)
            if let title = title {
                let lines = content.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                content = title + (lines.count > 1 ? "\n" + lines[1] : "")
            }
            note.body = crypto.seal(content)
            note.title = deriveTitle(from: content)
        }
        if let pinned = pinned { note.isPinned = pinned }
        if let archived = archived { note.isArchived = archived }
        if action == "delete" { note.deletedAt = note.deletedAt ?? Date() }
        if action == "restore" { note.deletedAt = nil }
        note.modifiedAt = Date()
        let previous = notes
        notes[i] = note
        save()
        if !lastSaveSucceeded { notes = previous; throw APIError(500, "保存失败") }
        return note
    }

    func setTodoArchived(id: UUID, archived: Bool, now: Date = Date()) {
        guard var item = todos().first(where: { $0.id == id }) else { return }
        item.archivedAt = archived ? now : nil
        if !archived { item.archiveRestoredAt = now }
        updateTodo(item)
    }

    func maintainTodoArchives(now: Date = Date()) {
        let existing = todos()
        var updated = existing
        for i in updated.indices {
            updated[i].normalizeCompletion(previous: existing[i], now: now)
            updated[i].archiveIfDue(now: now)
        }
        if updated != existing { saveTodos(updated) }
    }

    func editTodo(id: UUID, epoch: UUID, change: TodoChange) throws {
        guard epoch == LocalProfile.epoch else { throw APIError(409, "账号已切换，请重新打开任务") }
        var items = todos()
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw APIError(404, "任务已不存在") }
        switch change {
        case .title(let text, let previous):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 10000 else { throw APIError(400, "待办内容需为 1 至 10000 个字符") }
            guard items[index].text == previous else { throw APIError(409, "标题已在其他位置修改，请重新打开后编辑") }
            items[index].text = trimmed
        case .dueDate(let date, let previous):
            guard date?.timeIntervalSince1970.isFinite != false else { throw APIError(400, "到期时间无效") }
            guard items[index].dueAt?.timeIntervalSince1970 == previous?.timeIntervalSince1970 else {
                throw APIError(409, "到期时间已在其他位置修改，请重新打开后编辑")
            }
            items[index].dueAt = date
        case .toggleImportance:
            items[index].priority = items[index].priority == "high" ? "normal" : "high"
        }
        guard saveTodoMutation(items) else { throw APIError(500, "保存失败，请检查数据目录后重试") }
    }

    @discardableResult
    func deleteTodo(id: UUID, epoch: UUID = LocalProfile.epoch) -> Bool {
        guard epoch == LocalProfile.epoch else { return false }
        let items = todos()
        guard let item = items.first(where: { $0.id == id }), item.canDelete else { return false }
        return saveTodoMutation(items.filter { $0.id != id })
    }

    private func saveTodoMutation(_ items: [TodoItem]) -> Bool {
        guard canSave else { lastSaveSucceeded = false; return false }
        let previous = notes
        saveTodos(items)
        if !lastSaveSucceeded { notes = previous }
        return lastSaveSucceeded
    }
    func archivedNotes() -> [NoteRecord] { notes.filter { $0.isArchived && $0.deletedAt == nil } }
    func deletedNotes() -> [NoteRecord] {
        notes.filter { $0.deletedAt != nil }.sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    func body(of note: NoteRecord) -> String { crypto.open(note.body) }
    func body(id: UUID) -> String { note(id: id).map { crypto.open($0.body) } ?? "" }

    // MARK: 增改

    @discardableResult
    func create(body: String = "") -> NoteRecord {
        // 普通便签默认杏砂/雾紫交替，与 TODOList 专属绿色区分。
        let n = AppSettings.shared.noteCreationCount
        AppSettings.shared.noteCreationCount = n + 1
        var note = NoteRecord.make(colorName: NoteColor.defaultNames[n % NoteColor.defaultNames.count])
        note.body = crypto.seal(body)
        note.title = deriveTitle(from: body)
        notes.insert(note, at: 0)
        save()
        return note
    }

    func updateBody(id: UUID, body: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }), !notes[i].isTodoList else { return }
        var n = notes[i]
        n.body = crypto.seal(body)
        n.title = deriveTitle(from: body)
        n.modifiedAt = Date()
        notes[i] = n
        save()
    }

    func append(id: UUID, text: String) {
        if note(id: id)?.isTodoList == true {
            addTodos(text.split(whereSeparator: \.isNewline).map { TodoItem(text: String($0)) })
            return
        }
        EditorRegistry.shared.editor(for: id)?.saveNow()
        let current = body(id: id)
        let newBody = current.isEmpty ? text : current + "\n" + text
        updateBody(id: id, body: newBody)
    }

    func setColor(id: UUID, colorName: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        guard !notes[i].isTodoList else { return }
        notes[i].colorName = colorName
        save()
    }

    func cycleColor(id: UUID) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        guard !notes[i].isTodoList else { return }
        let names = NoteColor.all.map { $0.name }
        guard let idx = names.firstIndex(of: notes[i].colorName) else {
            notes[i].colorName = names[0]
            save()
            return
        }
        notes[i].colorName = names[(idx + 1) % names.count]
        save()
    }

    func togglePin(id: UUID) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        guard !notes[i].isTodoList else { return }
        notes[i].isPinned.toggle()
        save()
    }

    func setArchived(id: UUID, archived: Bool) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        guard !notes[i].isTodoList else { return }
        notes[i].isArchived = archived
        notes[i].modifiedAt = Date()
        save()
    }

    // MARK: 删除(软删除:进"已删除"区,可恢复)/ 撤销 / 彻底删除

    @discardableResult
    func delete(id: UUID) -> NoteRecord? {
        purgeTrash()
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return nil }
        guard !notes[i].isTodoList else { return nil }
        notes[i].deletedAt = Date()
        notes[i].modifiedAt = Date()
        trash = (notes[i], i)
        save()
        return notes[i]
    }

    /// 撤销(deck 删除 toast 用):恢复最近删除的那条
    func undoDelete() {
        guard let t = trash, let i = notes.firstIndex(where: { $0.id == t.note.id }) else { return }
        notes[i].deletedAt = nil
        trash = nil
        save()
    }

    /// 10 秒撤销窗口结束:仅清掉撤销令牌,便签留在"已删除"区
    func purgeTrash() {
        trash = nil
    }

    /// 从"已删除"区恢复
    func restore(id: UUID) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].deletedAt = nil
        notes[i].modifiedAt = Date()
        if trash?.note.id == id { trash = nil }
        save()
    }

    /// 彻底删除(从"已删除"区移除,不可恢复)
    func expunge(id: UUID) {
        notes.removeAll { $0.id == id && !$0.isTodoList }
        if trash?.note.id == id { trash = nil }
        save()
    }

    /// 自动清除:deletedAt 早于 cutoff 的彻底移除(启动时 + 每 6 小时)
    func purgeDeleted(olderThan days: Double = 30) {
        let cutoff = Date().addingTimeInterval(-days * 86400)
        let before = notes.count
        notes.removeAll { note in
            guard let d = note.deletedAt else { return false }
            return d < cutoff
        }
        if notes.count != before { save() }
    }

    // MARK: 排序(drag 拖拽)

    func moveVisible(from source: Int, to dest: Int) {
        var vis = visibleNotes()
        guard source >= 0, source < vis.count else { return }
        guard !vis[source].isTodoList else { return }
        let item = vis.remove(at: source)
        vis.insert(item, at: max(0, min(dest, vis.count)))
        let visibleIDs = Set(vis.map { $0.id })
        notes = vis + notes.filter { !visibleIDs.contains($0.id) }
        save()
    }

    func switchProfile(to profile: String, importing: Bool) throws {
        EditorRegistry.shared.saveAll()
        save()
        guard lastSaveSucceeded else { throw APIError(500, "当前数据保存失败，无法切换账号") }
        let target = LocalProfile.directory(profile)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = target.appendingPathComponent("notes.json")
        let imported = importing && !FileManager.default.fileExists(atPath: file.path) ? notes : nil
        // Decode before activating the profile. Never replace an unreadable file with an empty list.
        let loaded: [NoteRecord]
        if let imported = imported { loaded = imported }
        else if FileManager.default.fileExists(atPath: file.path) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            loaded = try decoder.decode([NoteRecord].self, from: Data(contentsOf: file))
        } else { loaded = [] }
        try validateEncryptedRecords(loaded)
        if let imported = imported {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            guard NoteStoreIO.atomicWrite(try encoder.encode(imported), to: file) else {
                throw APIError(500, "无法导入本机便签")
            }
        }
        try LocalProfile.activate(profile)
        notes = loaded
        trash = nil
        ensureTodoList()
        save()
    }

    func cloudEntities() -> [CloudEntity] {
        var result = notes.filter { !$0.isTodoList }.map { note in
            CloudEntity(id: note.id.uuidString, kind: "note", payload: [
                "title": .string(note.title), "body": .string(body(of: note)),
                "colorName": .string(note.colorName), "createdAt": .date(note.createdAt),
                "modifiedAt": .date(note.modifiedAt), "isPinned": .bool(note.isPinned),
                "isArchived": .bool(note.isArchived), "deletedAt": .date(note.deletedAt),
                "linkedTodoID": .uuid(note.linkedTodoID), "workflowID": .uuid(note.workflowID)])
        }
        result += todos().map { item in
            CloudEntity(id: item.id.uuidString, kind: "todo", payload: [
                "text": .string(item.text), "category": .string(item.category), "priority": .string(item.priority),
                "completed": .bool(item.completed), "dueAt": .date(item.dueAt),
                "tagIDs": .array((item.tagIDs ?? []).map { .string($0.uuidString) }),
                "completedAt": .date(item.completedAt), "archivedAt": .date(item.archivedAt),
                "archiveRestoredAt": .date(item.archiveRestoredAt),
                "number": item.number.map { .number(Double($0)) } ?? .null])
        }
        result += tags().map { tag in
            CloudEntity(id: tag.id.uuidString, kind: "tag", payload: [
                "name": .string(tag.name), "type": .string(tag.type),
                "details": .string(tag.details), "link": .string(tag.link), "modifiedAt": .date(tag.modifiedAt)])
        }
        return result
    }

    /// All fields are validated before the single atomic disk write. Called on the main thread.
    func applyCloud(_ entities: [CloudEntity]) throws {
        guard canSave else { throw APIError(500, "本机密钥或数据文件无法读取，已停止同步写入") }
        var next: [NoteRecord] = []
        var tasks: [TodoItem] = []
        var labels: [TodoTag] = []
        for entity in entities where !entity.deleted {
            guard let id = UUID(uuidString: entity.id) else { throw APIError(502, "云端记录编号无效") }
            let p = entity.payload
            if entity.kind == "todo" {
                guard let text = p["text"]?.string, let category = p["category"]?.string,
                      let priority = p["priority"]?.string, let completed = p["completed"]?.bool else {
                    throw APIError(502, "云端待办格式无效")
                }
                var todo = TodoItem(text: text, category: category, priority: priority, completed: completed)
                todo.id = id
                todo.number = p["number"]?.number.map { Int($0) }
                todo.dueAt = p["dueAt"]?.number.map { Date(timeIntervalSince1970: $0) }
                if case .array(let ids) = p["tagIDs"] { todo.tagIDs = ids.compactMap { $0.string.flatMap(UUID.init(uuidString:)) } }
                todo.completedAt = p["completedAt"]?.number.map { Date(timeIntervalSince1970: $0) }
                todo.archivedAt = p["archivedAt"]?.number.map { Date(timeIntervalSince1970: $0) }
                todo.archiveRestoredAt = p["archiveRestoredAt"]?.number.map { Date(timeIntervalSince1970: $0) }
                tasks.append(todo)
            } else if entity.kind == "tag" {
                guard let name = p["name"]?.string, let type = p["type"]?.string,
                      let details = p["details"]?.string, let link = p["link"]?.string else {
                    throw APIError(502, "云端标签格式无效")
                }
                labels.append(TodoTag(id: id, name: name, type: type, details: details, link: link,
                                      modifiedAt: p["modifiedAt"]?.number.map { Date(timeIntervalSince1970: $0) }))
            } else if entity.kind == "note" {
                guard let body = p["body"]?.string, let title = p["title"]?.string,
                      let created = p["createdAt"]?.number, let modified = p["modifiedAt"]?.number else {
                    throw APIError(502, "云端便签格式无效")
                }
                var note = NoteRecord.make(colorName: p["colorName"]?.string ?? "雾紫")
                note.id = id; note.title = title; note.body = crypto.seal(body)
                note.createdAt = Date(timeIntervalSince1970: created)
                note.modifiedAt = Date(timeIntervalSince1970: modified)
                note.isPinned = p["isPinned"]?.bool ?? false; note.isArchived = p["isArchived"]?.bool ?? false
                note.deletedAt = p["deletedAt"]?.number.map { Date(timeIntervalSince1970: $0) }
                note.linkedTodoID = p["linkedTodoID"]?.string.flatMap(UUID.init(uuidString:))
                note.workflowID = p["workflowID"]?.string.flatMap(UUID.init(uuidString:))
                next.append(note)
            }
        }
        // Preserve the local visible order; new remote records follow by creation date.
        let order = Dictionary(uniqueKeysWithValues: notes.enumerated().map { ($0.element.id, $0.offset) })
        next.sort { (order[$0.id] ?? Int.max, -$0.createdAt.timeIntervalSince1970) < (order[$1.id] ?? Int.max, -$1.createdAt.timeIntervalSince1970) }
        var todoNote = todoList ?? NoteRecord.make(colorName: NoteColor.todo.name)
        todoNote.kind = "todoList"; todoNote.title = NoteRecord.todoListTitle; todoNote.isPinned = true
        // Unsynced local tasks keep distinct temporary numbers until the server assigns canonical ones.
        var used = Set<Int>()
        var sequence = max(todoNote.todoSequence ?? 0, tasks.compactMap { $0.number }.max() ?? 0)
        for i in tasks.indices {
            if tasks[i].number == nil || used.contains(tasks[i].number!) {
                sequence += 1; tasks[i].number = sequence
            }
            used.insert(tasks[i].number!)
        }
        tasks.sort { ($0.number ?? 0) < ($1.number ?? 0) }
        todoNote.todoData = crypto.seal(String(decoding: try JSONEncoder().encode(tasks), as: UTF8.self))
        todoNote.body = crypto.seal(tasks.map { $0.taskLine }.joined(separator: "\n"))
        todoNote.tagData = crypto.seal(String(decoding: try JSONEncoder().encode(labels), as: UTF8.self))
        todoNote.todoSequence = sequence
        let all = [todoNote] + next
        guard NoteStoreIO.save(all) else { throw APIError(500, "同步数据无法保存到本机") }
        notes = all
        lastSaveSucceeded = true
        OverdueWatcher.shared.refreshSoon()
    }

    private func validateEncryptedRecords(_ records: [NoteRecord]) throws {
        guard Set(records.map { $0.id }).count == records.count else { throw APIError(500, "便签编号重复，已停止写入") }
        for note in records {
            _ = try crypto.openChecked(note.body)
            if let sealed = note.tagData {
                let labels = try JSONDecoder().decode([TodoTag].self, from: Data(crypto.openChecked(sealed).utf8))
                guard Set(labels.map { $0.id }).count == labels.count else { throw APIError(500, "标签编号重复") }
            }
            if let sealed = note.todoData, !sealed.isEmpty {
                let text = try crypto.openChecked(sealed)
                let tasks = try JSONDecoder().decode([TodoItem].self, from: Data(text.utf8))
                guard Set(tasks.map { $0.id }).count == tasks.count else { throw APIError(500, "待办编号重复，已停止写入") }
            }
        }
    }

    private var canSave: Bool {
        let expected = crypto.key.withUnsafeBytes { Data($0) }
        return !integrityFailed && !NoteStoreIO.loadFailed && (try? Data(contentsOf: AppPaths.keyFile)) == expected
    }

    private func save() {
        let keyOnDisk = try? Data(contentsOf: AppPaths.keyFile)
        let expectedKey = crypto.key.withUnsafeBytes { Data($0) }
        lastSaveSucceeded = canSave && keyOnDisk == expectedKey && NoteStoreIO.save(notes)
        if lastSaveSucceeded { NotificationCenter.default.post(name: .enoteLocalSaved, object: nil) }
        OverdueWatcher.shared.refreshSoon()
    }
}
