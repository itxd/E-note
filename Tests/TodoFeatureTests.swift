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
    assert(store.tags().contains(tag))
    assert(store.todo(identifier: created.id.uuidString)!.tagIDs == [tag.id])
    assert(store.todo(identifier: created.id.uuidString)!.isArchived)
    store.setTodoArchived(id: created.id, archived: false)
    store.maintainTodoArchives()
    assert(!store.todo(identifier: created.id.uuidString)!.isArchived)
    print("PASS: legacy decoding, archive boundary, completion transitions, restore and tag cloud round-trip")
}
