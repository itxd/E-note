import Foundation

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
}
