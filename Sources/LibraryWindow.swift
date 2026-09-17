import SwiftUI
import AppKit

// MARK: - All Notes / Archive / 已删除 窗口(⌥⌘A / ⌥⌘L)

final class LibraryState: ObservableObject {
    static let shared = LibraryState()
    @Published var tab = 0
}

final class LibraryWindowController: NSWindowController {
    private static let titles = ["E note 便签库", "E note 归档", "E note 已删除"]

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 500),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = Self.titles[0]
        window.minSize = NSSize(width: 580, height: 380)
        window.contentView = NSHostingView(rootView: LibraryView())
        window.center()
        self.init(window: window)
    }

    func show(tab: Int) {
        let tab = min(max(tab, 0), 2)
        LibraryState.shared.tab = tab
        if let window = window {
            window.title = Self.titles[tab]
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }
}

struct LibraryView: View {
    @ObservedObject var store = NoteStore.shared
    @ObservedObject var state = LibraryState.shared
    @State private var query = ""
    @State private var selected: UUID?

    private var filtered: [NoteRecord] {
        let base: [NoteRecord]
        switch state.tab {
        case 1: base = store.archivedNotes()
        case 2: base = store.deletedNotes()
        default: base = store.libraryNotes()
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return base }
        return base.filter { note in
            if note.title.localizedCaseInsensitiveContains(q) { return true }
            return store.body(of: note).localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $state.tab) {
                    Text("全部便签").tag(0)
                    Text("归档").tag(1)
                    Text("已删除").tag(2)
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                .onChange(of: state.tab) { _ in selected = nil }
                TextField("搜索标题或正文…", text: $query)
                    .textFieldStyle(.roundedBorder)
                Spacer(minLength: 0)
            }
            .padding(10)
            Divider()
            HSplitView {
                List(selection: $selected) {
                    ForEach(filtered) { note in
                        LibraryRow(note: note, isDeleted: state.tab == 2)
                            .tag(note.id)
                    }
                }
                .frame(minWidth: 220, idealWidth: 250, maxWidth: 350)
                detailPane
                    .frame(minWidth: 320)
            }
        }
        .frame(minWidth: 580, minHeight: 380)
    }

    @ViewBuilder
    private var detailPane: some View {
        if let id = selected, let note = store.note(id: id) {
            let isDeleted = note.deletedAt != nil
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(NoteColor.named(note.colorName).tab)
                        .frame(width: 10, height: 10)
                    if let todoID = note.linkedTodoID, let task = store.todo(identifier: todoID.uuidString) {
                        Text(task.code).font(.system(.caption, design: .monospaced)).foregroundColor(TodoTheme.accent)
                    }
                    Text(note.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if isDeleted, let d = note.deletedAt {
                        Text("删除于 \(formatNoteDate(d))")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    } else {
                        Text(formatNoteDate(note.modifiedAt))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    if isDeleted {
                        Button("恢复") { store.restore(id: note.id) }
                        Button("彻底删除") { expunge(note: note) }
                    } else {
                        if note.isArchived {
                            Button("恢复") { store.setArchived(id: note.id, archived: false) }
                        } else {
                            Button("归档") { store.setArchived(id: note.id, archived: true) }.disabled(note.isTodoList)
                        }
                        Button("删除") { delete(note: note) }.disabled(note.isTodoList)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
                if note.isTodoList {
                    TodoListView(onOpenNote: { selected = $0 }).id(LocalProfile.epoch)
                } else {
                    NoteEditor(noteID: note.id, deck: nil)
                        .id(LocalProfile.epoch.uuidString + note.id.uuidString)
                        .background(NoteColor.named(note.colorName).paper)
                }
            }
        } else {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: state.tab == 2 ? "trash" : "note.text")
                    .font(.system(size: 32))
                    .foregroundColor(.secondary)
                Text(state.tab == 2 ? "已删除的便签会在这里保留 30 天" : "选择左侧的一条便签")
                    .foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// 删除:软删除进"已删除"区,并自动选中下一条(删最后一个则选前一个)
    private func delete(note: NoteRecord) {
        let oldIndex = filtered.firstIndex(where: { $0.id == note.id })
        if let deleted = store.delete(id: note.id) {
            UndoToastController.shared.show(deletedTitle: deleted.title)
        }
        selectNeighbor(deletedIndex: oldIndex)
    }

    /// 彻底删除:直接从列表移除,并自动选中下一条
    private func expunge(note: NoteRecord) {
        let oldIndex = filtered.firstIndex(where: { $0.id == note.id })
        store.expunge(id: note.id)
        selectNeighbor(deletedIndex: oldIndex)
    }

    private func selectNeighbor(deletedIndex: Int?) {
        guard let oldIndex = deletedIndex else { selected = nil; return }
        let remaining = filtered
        guard !remaining.isEmpty else { selected = nil; return }
        selected = remaining[min(oldIndex, remaining.count - 1)].id
    }
}

struct LibraryRow: View {
    let note: NoteRecord
    /// 已删除区:显示删除时间
    let isDeleted: Bool

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(NoteColor.named(note.colorName).tab)
                .frame(width: 5, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if note.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }
                    Text(note.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                }
                if isDeleted, let d = note.deletedAt {
                    Text("删除于 \(formatNoteDate(d))")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                } else {
                    Text(formatNoteDate(note.modifiedAt))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
