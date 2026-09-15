import SwiftUI
import AppKit

// MARK: - ⇧⌘Space 悬浮快速捕捉框

final class QuickCaptureController {
    static let shared = QuickCaptureController()

    /// 作为 Picker 的“新建便签”哨兵值
    let newNoteSentinel = UUID()
    private var panel: NSPanel?

    var isOpen: Bool { panel != nil }

    func toggle() {
        if panel != nil { close() } else { show() }
    }

    func show() {
        guard panel == nil, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        NSApp.activate(ignoringOtherApps: true)

        let size = NSSize(width: 420, height: 220)
        let rect = NSRect(x: screen.visibleFrame.midX - size.width / 2,
                          y: screen.visibleFrame.midY - size.height / 2,
                          width: size.width,
                          height: size.height)
        let p = NSPanel(contentRect: rect,
                        styleMask: [.titled, .closable, .fullSizeContentView],
                        backing: .buffered,
                        defer: false)
        p.title = "快速捕捉"
        p.titlebarAppearsTransparent = true
        p.isFloatingPanel = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        p.contentView = NSHostingView(rootView: QuickCaptureView(controller: self))
        panel = p
        p.center()
        p.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    func submit(text: String, target: UUID) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            if target == newNoteSentinel {
                NoteStore.shared.create(body: trimmed)
            } else {
                NoteStore.shared.append(id: target, text: trimmed)
            }
        }
        close()
    }
}

// MARK: - 捕捉输入框(↩ 保存,⇧↩ 换行,Esc 取消)

final class CaptureTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 { // Return
            if event.modifierFlags.contains(.shift) {
                insertNewline(nil)
            } else {
                onSubmit?()
            }
            return
        }
        if event.keyCode == 53 { // Esc
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }
}

struct CaptureEditor: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        let tv = CaptureTextView()
        tv.onSubmit = { context.coordinator.parent.onSubmit() }
        tv.onCancel = { context.coordinator.parent.onCancel() }
        tv.isRichText = false
        tv.font = NSFont.systemFont(ofSize: 14)
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.autoresizingMask = [.width]
        tv.string = text
        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {}

    final class Coordinator: NSObject {
        var parent: CaptureEditor
        init(_ parent: CaptureEditor) { self.parent = parent }
    }
}

struct QuickCaptureView: View {
    let controller: QuickCaptureController
    @ObservedObject var store = NoteStore.shared
    @State private var text = ""
    @State private var target: UUID

    init(controller: QuickCaptureController) {
        self.controller = controller
        _target = State(initialValue: controller.newNoteSentinel)
    }

    var body: some View {
        VStack(spacing: 10) {
            CaptureEditor(text: $text,
                          onSubmit: { controller.submit(text: text, target: target) },
                          onCancel: { controller.close() })
            .frame(maxWidth: .infinity, minHeight: 90, maxHeight: .infinity)
            HStack {
                Picker("保存到", selection: $target) {
                    Text("新建便签").tag(controller.newNoteSentinel)
                    ForEach(store.visibleNotes()) { note in
                        Text(note.title).tag(note.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
                Spacer()
                Button("取消") { controller.close() }
                    .keyboardShortcut(.cancelAction)
                Button("保存(↩)") { controller.submit(text: text, target: target) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(width: 420, height: 220)
    }
}
