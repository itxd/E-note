import SwiftUI
import AppKit

struct TodoTag: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var type = "项目"
    var details = ""
    var link = ""
    var modifiedAt: Date? = nil
}

final class TagWindowController: NSWindowController {
    static let shared = TagWindowController()
    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "标签管理"
        window.minSize = NSSize(width: 650, height: 460)
        super.init(window: window)
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func show(tag: TodoTag? = nil) {
        window?.contentView = NSHostingView(rootView: TagManagerView(selected: tag))
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct TagManagerView: View {
    @ObservedObject private var store = NoteStore.shared
    @State var selected: TodoTag?
    @State private var query = ""
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("搜索标签", text: $query)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(store.tags().filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { tag in
                            Button { selected = tag } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(tag.name).fontWeight(.medium)
                                    Text(tag.type).font(.caption).foregroundColor(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                    .background(selected?.id == tag.id ? TodoTheme.accent.opacity(0.12) : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
                Button { selected = TodoTag() } label: { Label("新建标签", systemImage: "plus") }
            }.padding(16).frame(width: 200)
            Divider()
            if let selected = selected {
                TagEditorView(tag: selected).id(selected.id)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "tag").font(.largeTitle)
                    Text("选择或新建一个标签")
                    Text("把项目背景、版本范围和相关链接放在一起。")
                        .font(.caption).foregroundColor(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onReceive(store.$notes) { _ in
            if editorEpoch != LocalProfile.epoch { selected = nil; editorEpoch = LocalProfile.epoch }
        }
        .tint(TodoTheme.accent)
    }
    @State private var editorEpoch = LocalProfile.epoch
}

private struct TagEditorView: View {
    @State var tag: TodoTag
    @State private var message = ""
    @State private var baseline: TodoTag?
    @State private var epoch = LocalProfile.epoch
    @ObservedObject private var store = NoteStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("标签资料").font(.title2.bold())
            TextField("标签名称，例如 E note 或 v1.2", text: $tag.name)
            Picker("类型", selection: $tag.type) {
                Text("项目").tag("项目"); Text("版本").tag("版本"); Text("其他").tag("其他")
            }
            Text("说明 · 项目背景、版本目标或使用约定").font(.caption).foregroundColor(.secondary)
            TextEditor(text: $tag.details).font(.body)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.2)))
            TextField("相关链接（可选）", text: $tag.link)
            Text("修改资料后，所有绑定此标签的 TODO 都会显示最新信息。")
                .font(.caption).foregroundColor(.secondary)
            HStack {
                Text(message).font(.caption).foregroundColor(.secondary)
                Spacer()
                Button("保存标签") {
                    guard epoch == LocalProfile.epoch else { message = "账号已切换，请重新打开"; return }
                    guard store.tags().first(where: { $0.id == tag.id }) == baseline else {
                        message = "标签已在其他窗口或设备更新，请重新选择后编辑"; return
                    }
                    tag.name = tag.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.saveTag(tag)
                    baseline = store.tags().first { $0.id == tag.id }
                    message = store.lastSaveSucceeded ? "已保存" : "保存失败，请检查数据目录"
                }.buttonStyle(.borderedProminent)
                    .disabled(tag.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || tag.name.count > 80 || tag.details.count > 20000 || tag.link.count > 2000)
            }
        }.padding(20).textFieldStyle(.roundedBorder)
            .onAppear { baseline = store.tags().first { $0.id == tag.id } }
    }
}

struct TodoTagPicker: View {
    @ObservedObject private var store = NoteStore.shared
    let itemID: UUID
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("绑定标签").font(.headline)
            if store.tags().isEmpty { Text("先新建标签，再绑定到待办。") .foregroundColor(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(store.tags()) { tag in
                        Toggle(isOn: Binding(get: {
                            store.todos().first { $0.id == itemID }?.tagIDs?.contains(tag.id) == true
                        }, set: { selected in
                            guard var current = store.todos().first(where: { $0.id == itemID }) else { return }
                            var ids = Set(current.tagIDs ?? [])
                            if selected && ids.count >= 100 { return }
                            if selected { ids.insert(tag.id) } else { ids.remove(tag.id) }
                            current.tagIDs = ids.sorted { $0.uuidString < $1.uuidString }
                            store.updateTodo(current)
                        })) { Text(tag.name + " · " + tag.type) }
                    }
                }
            }.frame(maxHeight: 230)
            Button("新建 / 管理标签…") { TagWindowController.shared.show() }
        }.padding(16).frame(width: 270)
    }
}

struct TagInfoView: View {
    @ObservedObject private var store = NoteStore.shared
    let tagID: UUID
    var body: some View {
        if let tag = store.tags().first(where: { $0.id == tagID }) {
            VStack(alignment: .leading, spacing: 12) {
                Text(tag.name).font(.headline)
                Text(tag.type).font(.caption).foregroundColor(.secondary)
                ScrollView { Text(tag.details.isEmpty ? "暂无说明" : tag.details).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 200)
                if !tag.link.isEmpty {
                    if let url = URL(string: tag.link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                        Link(tag.link, destination: url)
                    } else { Text(tag.link).textSelection(.enabled) }
                }
                Button("编辑标签资料…") { TagWindowController.shared.show(tag: tag) }
            }.padding(16).frame(width: 300)
        }
    }
}
