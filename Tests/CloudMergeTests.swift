import Foundation
import AppKit

func runCloudMergeTests() {
    let base = CloudEntity(id: UUID().uuidString, kind: "todo", revision: 4, payload: [
        "text": .string("original"), "completed": .bool(false), "category": .string("work"), "number": .number(1)])
    var local = base; local.payload["text"] = .string("local edit")
    var remote = base; remote.revision = 5; remote.payload["completed"] = .bool(true)
    let (merged, conflict) = CloudMerge.merge(base: base, local: local, remote: remote)
    precondition(conflict == nil && merged?.payload["text"]?.string == "local edit" && merged?.payload["completed"]?.bool == true)
    remote.payload["text"] = .string("remote edit")
    let (_, divergent) = CloudMerge.merge(base: base, local: local, remote: remote)
    precondition(divergent?.fields == ["text"])
    remote.deleted = true
    precondition(CloudMerge.merge(base: base, local: local, remote: remote).1 != nil)
    precondition(CloudMerge.merge(base: base, local: base, remote: remote).0?.deleted == true)
    precondition(CloudMerge.merge(base: base, local: nil, remote: base).0?.deleted == true)
    precondition(CloudMerge.merge(base: nil, local: nil, remote: base).0 == base)
    var renumbered = base; renumbered.payload["number"] = .number(8)
    precondition(CloudMerge.merge(base: base, local: base, remote: renumbered).0?.payload["number"]?.number == 8)
    print("PASS three-way merge: disjoint fields, divergent edits, delete/edit, remote create, account numbering")
}

func runProfileIsolationTests() throws {
    let store = NoteStore.shared
    let original = store.create(body: "offline original")
    let coordinator = NoteEditorCoordinator(noteID: original.id, deck: nil)
    coordinator.textView = EditorTextView()
    coordinator.textView!.string = "offline unsaved edit"
    EditorRegistry.shared.register(coordinator, for: original.id)
    coordinator.scheduleSave()
    try store.switchProfile(to: String(repeating: "a", count: 64), importing: true)
    precondition(store.body(id: original.id) == "offline unsaved edit")
    coordinator.textView!.string = "STALE CROSS ACCOUNT EDIT"
    coordinator.scheduleSave(); coordinator.saveNow()
    precondition(store.body(id: original.id) == "offline unsaved edit")
    try store.switchProfile(to: "offline", importing: false)
    coordinator.saveNow()
    precondition(store.body(id: original.id) == "offline unsaved edit")
    EditorRegistry.shared.unregister(coordinator, for: original.id)
    print("PASS account epoch isolation: pending editor flush, stale callbacks cannot write another account or a reopened profile")
}
