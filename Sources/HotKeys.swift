import Foundation
import Carbon

// MARK: - 全局快捷键(Carbon RegisterEventHotKey,无需辅助功能权限)

final class HotKeyCenter {
    static let shared = HotKeyCenter()

    // Carbon modifier bit
    private static let cmd: UInt32 = 0x0100
    private static let shift: UInt32 = 0x0200
    private static let option: UInt32 = 0x0800

    private var handlers: [UInt32: () -> Void] = [:]
    private var hotKeyRefs: [EventHotKeyRef?] = []

    func install() {
        var spec = EventTypeSpec(eventClass: UInt32(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event,
                              EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil,
                              MemoryLayout<EventHotKeyID>.size,
                              nil,
                              &hotKeyID)
            HotKeyCenter.shared.handlers[hotKeyID.id]?()
            return noErr
        } as EventHandlerUPP, 1, &spec, nil, nil)
    }

    func register(keyCode: Int, carbonModifiers mods: UInt32, id: UInt32, handler: @escaping () -> Void) {
        handlers[id] = handler
        let hotKeyID = EventHotKeyID(signature: OSType(0x4E6F7479), id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), mods, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref = ref {
            hotKeyRefs.append(ref)
        }
    }

    // 固定快捷键表
    func registerDefaults(newNote: @escaping () -> Void,
                          quickCapture: @escaping () -> Void,
                          allNotes: @escaping () -> Void,
                          archive: @escaping () -> Void) {
        register(keyCode: kVK_ANSI_N, carbonModifiers: HotKeyCenter.cmd | HotKeyCenter.option, id: 1, handler: newNote)
        register(keyCode: kVK_Space, carbonModifiers: HotKeyCenter.cmd | HotKeyCenter.shift, id: 2, handler: quickCapture)
        register(keyCode: kVK_ANSI_A, carbonModifiers: HotKeyCenter.cmd | HotKeyCenter.option, id: 3, handler: allNotes)
        register(keyCode: kVK_ANSI_L, carbonModifiers: HotKeyCenter.cmd | HotKeyCenter.option, id: 4, handler: archive)
    }
}
