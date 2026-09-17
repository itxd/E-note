import Foundation
import AppKit

func runTodoFeatureTests() throws {
    let old = """
    {"id":"00000000-0000-0000-0000-000000000001","text":"旧任务","category":"工作","priority":"normal","completed":true}
    """
    var item = try JSONDecoder().decode(TodoItem.self, from: Data(old.utf8))
    assert(item.tagIDs == nil && item.completedAt == nil && !item.isArchived)
    let now = Date(timeIntervalSince1970: 1800000000)
    item.normalizeCompletion(previous: item, now: now)
    assert(item.completedAt == now)
    item.archiveIfDue(now: now.addingTimeInterval(3 * 86400 - 1))
    assert(!item.isArchived)
    item.archiveIfDue(now: now.addingTimeInterval(3 * 86400))
    assert(item.isArchived)
    item.archivedAt = nil; item.archiveRestoredAt = now.addingTimeInterval(3 * 86400)
    item.archiveIfDue(now: now.addingTimeInterval(3 * 86400 + 30))
    assert(!item.isArchived)
    let previous = item
    item.completed = false
    item.normalizeCompletion(previous: previous, now: now)
    assert(item.completedAt == nil && item.archiveRestoredAt == nil)

    let store = NoteStore.shared
    var tag = TodoTag(name: "E note v2", type: "版本", details: "项目背景和版本验收范围", link: "https://example.com")
    store.saveTag(tag)
    tag = store.tags().first { $0.id == tag.id }!
    var task = TodoItem(text: "带标签的任务")
    task.tagIDs = [tag.id]
    let created = store.addTodos([task])[0]
    var complete = created; complete.completed = true
    store.updateTodo(complete)
    let completed = store.todo(identifier: created.id.uuidString)!
    assert(completed.completedAt != nil)
    store.maintainTodoArchives(now: completed.completedAt!.addingTimeInterval(3 * 86400))
    assert(store.todo(identifier: created.id.uuidString)!.isArchived)
    let entities = store.cloudEntities()
    assert(entities.contains { $0.id == tag.id.uuidString && $0.kind == "tag" })
    try store.applyCloud(entities)
    var restoredTag = store.tags().first { $0.id == tag.id }!
    // Unix timestamps and Foundation's reference date can differ by a fraction
    // of a microsecond after conversion. Verify time and content separately.
    assert(abs(restoredTag.modifiedAt!.timeIntervalSince(tag.modifiedAt!)) < 0.000001)
    restoredTag.modifiedAt = tag.modifiedAt
    assert(restoredTag == tag)
    assert(store.todo(identifier: created.id.uuidString)!.tagIDs == [tag.id])
    assert(store.todo(identifier: created.id.uuidString)!.isArchived)
    store.setTodoArchived(id: created.id, archived: false)
    store.maintainTodoArchives()
    assert(!store.todo(identifier: created.id.uuidString)!.isArchived)
    assert(store.todoList?.title == "待办清单")
    let profile = LocalProfile.current
    let enabled = AppSettings.shared.todoListEnabled
    let legacyProfile = LocalProfile.key(server: "test-title-migration", account: UUID().uuidString)
    let directory = LocalProfile.directory(legacyProfile)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var legacyNotes = store.notes
    let index = legacyNotes.firstIndex { $0.isTodoList }!
    legacyNotes[index].title = "TODOList"
    let legacyList = legacyNotes[index]
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    let legacyData = try encoder.encode(legacyNotes)
    assert(NoteStoreIO.atomicWrite(legacyData, to: directory.appendingPathComponent("notes.json")))
    AppSettings.shared.todoListEnabled = false
    try store.switchProfile(to: legacyProfile, importing: false)
    let migrated = store.todoList!
    assert(migrated.title == "待办清单" && migrated.id == legacyList.id)
    assert(migrated.todoData == legacyList.todoData && migrated.tagData == legacyList.tagData)
    assert(migrated.todoSequence == legacyList.todoSequence && migrated.kind == "todoList")
    assert(!AppSettings.shared.todoListEnabled)
    assert(NoteStoreIO.load().first { $0.isTodoList }?.title == "待办清单")
    try store.switchProfile(to: profile, importing: false)
    AppSettings.shared.todoListEnabled = enabled
    print("PASS: legacy TODOList title migrates without changing tasks, tags, IDs or visibility")
    print("PASS: legacy decoding, archive boundary, completion transitions, restore and tag cloud round-trip")
    try runTodoActionTests()
}

func runTodoActionTests() throws {
    let store = NoteStore.shared
    let epoch = LocalProfile.epoch
    let first = store.addTodos([TodoItem(text: "原始标题", category: "测试")])[0]
    let id = first.id
    assert(!first.canDelete && !store.deleteTodo(id: id))

    let linked = try store.ensureLinkedNote(todoID: id, epoch: epoch)
    assert(linked.linkedTodoID == id && store.body(of: linked).contains(first.code))
    let reused = try store.ensureLinkedNote(todoID: id, epoch: epoch)
    assert(reused.id == linked.id)
    store.setArchived(id: linked.id, archived: true)
    let unarchived = try store.ensureLinkedNote(todoID: id, epoch: epoch)
    assert(!unarchived.isArchived)
    _ = store.delete(id: linked.id)
    let restored = try store.ensureLinkedNote(todoID: id, epoch: epoch)
    assert(restored.id == linked.id && restored.deletedAt == nil)
    assert(store.notes.filter { $0.linkedTodoID == id }.count == 1)
    do {
        _ = try store.ensureLinkedNote(todoID: id, epoch: UUID())
        assertionFailure("stale account created a linked note")
    } catch let error as APIError { assert(error.status == 409) }
    if let screen = NSScreen.main {
        let deck = DeckController(screen: screen)
        deck.expand(store.todoList!, focus: false)
        let width = deck.noteWidth, height = deck.noteHeight
        deck.toggleEnlarged()
        assert(deck.noteWidth == min(width * 2.5, screen.visibleFrame.width - deck.cardWidth * 2))
        assert(deck.noteHeight == min(height * 2.5, screen.visibleFrame.height - 16))
        deck.toggleEnlarged()
        assert(deck.noteWidth == width && deck.noteHeight == height)
        deck.teardown()
    }

    // An open title editor must preserve changes made to other fields.
    var external = first
    external.priority = "high"
    external.dueAt = Date(timeIntervalSince1970: 1900000000)
    external.tagIDs = store.tags().map { $0.id }
    external.completed = true
    store.updateTodo(external)
    try store.editTodo(id: id, epoch: epoch, change: .title("  修改后的标题  ", replacing: first.text))
    var current = store.todo(identifier: id.uuidString)!
    assert(current.text == "修改后的标题" && current.priority == "high")
    assert(current.dueAt == external.dueAt && current.tagIDs == external.tagIDs)
    assert(current.completed && current.completedAt != nil && current.number == first.number)
    do {
        try store.editTodo(id: id, epoch: epoch, change: .title("旧窗口覆盖", replacing: first.text))
        assertionFailure("stale title overwrote newer text")
    } catch let error as APIError { assert(error.status == 409) }
    do {
        try store.editTodo(id: id, epoch: epoch, change: .title(" \n ", replacing: current.text))
        assertionFailure("blank title accepted")
    } catch let error as APIError { assert(error.status == 400) }

    let nextDue = Date(timeIntervalSince1970: 1900003600)
    try store.editTodo(id: id, epoch: epoch, change: .dueDate(nextDue, replacing: current.dueAt))
    do {
        try store.editTodo(id: id, epoch: epoch, change: .dueDate(nil, replacing: external.dueAt))
        assertionFailure("stale date editor cleared a newer date")
    } catch let error as APIError { assert(error.status == 409) }
    try store.editTodo(id: id, epoch: epoch, change: .dueDate(nil, replacing: nextDue))
    try store.editTodo(id: id, epoch: epoch, change: .toggleImportance)
    current = store.todo(identifier: id.uuidString)!
    assert(current.dueAt == nil && current.priority == "normal" && current.completed)
    assert(current.text == "修改后的标题" && current.tagIDs == external.tagIDs)
    try store.editTodo(id: id, epoch: epoch, change: .toggleImportance)
    assert(store.todo(identifier: id.uuidString)!.priority == "high")

    // A failed atomic rename must not leave a successful-looking in-memory edit.
    let beforeFailure = store.todo(identifier: id.uuidString)!
    let savedBytes = try Data(contentsOf: AppPaths.notesFile)
    let backup = AppPaths.notesFile.appendingPathExtension("test-backup")
    try FileManager.default.moveItem(at: AppPaths.notesFile, to: backup)
    try FileManager.default.createDirectory(at: AppPaths.notesFile, withIntermediateDirectories: false)
    do {
        defer {
            try! FileManager.default.removeItem(at: AppPaths.notesFile)
            try! FileManager.default.moveItem(at: backup, to: AppPaths.notesFile)
        }
        do {
            try store.editTodo(id: id, epoch: epoch, change: .toggleImportance)
            assertionFailure("failed disk write was reported as successful")
        } catch let error as APIError { assert(error.status == 500) }
        assert(store.todo(identifier: id.uuidString) == beforeFailure)
        assert(!store.deleteTodo(id: id, epoch: epoch))
        assert(store.todo(identifier: id.uuidString) == beforeFailure)
        let unchangedBytes = try Data(contentsOf: backup)
        assert(unchangedBytes == savedBytes)
    }

    // Reopening a task while a delete confirmation is open revokes deletion.
    var reopened = store.todo(identifier: id.uuidString)!
    assert(reopened.canDelete)
    reopened.completed = false; store.updateTodo(reopened)
    assert(!store.deleteTodo(id: id, epoch: epoch))
    store.setTodoArchived(id: id, archived: true)
    assert(store.todo(identifier: id.uuidString)!.canDelete)
    store.setTodoArchived(id: id, archived: false)
    assert(!store.deleteTodo(id: id, epoch: epoch))
    store.setTodoArchived(id: id, archived: true)
    assert(store.deleteTodo(id: id, epoch: epoch))
    assert(store.todo(identifier: id.uuidString) == nil)

    let completed = store.addTodos([TodoItem(text: "已完成可删除", completed: true)])[0]
    let profile = LocalProfile.current
    let other = LocalProfile.key(server: "test-action-isolation", account: UUID().uuidString)
    try store.switchProfile(to: other, importing: true)
    let imported = store.todo(identifier: completed.id.uuidString)!
    do {
        try store.editTodo(id: completed.id, epoch: epoch, change: .toggleImportance)
        assertionFailure("old account action modified imported task")
    } catch let error as APIError { assert(error.status == 409) }
    assert(!store.deleteTodo(id: completed.id, epoch: epoch))
    assert(store.todo(identifier: completed.id.uuidString) == imported)
    try store.switchProfile(to: profile, importing: false)
    assert(!store.deleteTodo(id: completed.id, epoch: epoch))
    assert(store.deleteTodo(id: completed.id, epoch: LocalProfile.epoch))
    print("PASS: direct title/date/priority edits, field conflicts, delete eligibility and stale account actions")
}
