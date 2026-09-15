import SwiftUI
import AppKit

// MARK: - 删除后 10 秒撤销 toast

final class UndoToastController {
    static let shared = UndoToastController()
    private var panel: NSPanel?

    func show(deletedTitle: String) {
        dismiss()
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let size = NSSize(width: 340, height: 48)
        let rect = NSRect(x: screen.visibleFrame.midX - size.width / 2,
                          y: screen.visibleFrame.minY + 40,
                          width: size.width,
                          height: size.height)
        let p = NSPanel(contentRect: rect,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        p.isFloatingPanel = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        p.contentView = NSHostingView(rootView: UndoToastView(title: deletedTitle))
        panel = p
        p.orderFrontRegardless()
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}

struct UndoToastView: View {
    let title: String
    @State private var secondsLeft = 10

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "trash.fill")
                .foregroundColor(.secondary)
            Text("已删除「\(title)」")
                .lineLimit(1)
                .font(.system(size: 13))
            Spacer(minLength: 0)
            Button("撤销") {
                NoteStore.shared.undoDelete()
                UndoToastController.shared.dismiss()
            }
            Text("\(secondsLeft)s")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 28)
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(radius: 6)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if secondsLeft > 1 {
                secondsLeft -= 1
            } else {
                NoteStore.shared.purgeTrash()
                UndoToastController.shared.dismiss()
            }
        }
    }
}
