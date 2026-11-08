import AppKit
import Carbon.HIToolbox

/// 全域快捷鍵 ⌃⌥T：在任何 App 裡叫出／收起 TidyDay，並把游標放進輸入框（參考 Things 3 Quick Entry）。
/// 用 Carbon 的 RegisterEventHotKey，不需要「輔助使用」權限。
/// 不用 ⌃⌥Space：macOS 預設拿它切換輸入法。
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()
    static let storageKey = "globalHotKeyEnabled"
    static let focusInput = Notification.Name("TidyDayFocusInput")

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: storageKey) as? Bool ?? true
    }

    func apply() {
        Self.isEnabled ? register() : unregister()
    }

    private func register() {
        guard ref == nil else { return }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotKey.toggleWindow() } }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x5444_4159), id: 1) // "TDAY"
        RegisterEventHotKey(UInt32(kVK_ANSI_T), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
    }

    private func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    static func toggleWindow() {
        let c = StatusController.shared
        c.isOpen ? c.close() : c.open(focusInput: true)
    }

}
