import Carbon.HIToolbox
import Foundation

/// Global shortcuts via Carbon `RegisterEventHotKey`. Unlike global key-event monitors, this needs
/// no Input Monitoring or Accessibility permission, and it keeps working while classification hangs.
final class HotKeys {
    static let shared = HotKeys()

    struct Binding {
        let id: UInt32
        let keyCode: Int
        let display: String
    }

    static let modifiers = cmdKey | optionKey | controlKey
    static let pause = Binding(id: 1, keyCode: kVK_ANSI_P, display: "⌃⌥⌘P")
    static let reveal = Binding(id: 2, keyCode: kVK_ANSI_R, display: "⌃⌥⌘R")

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var installed = false
    private let signature: OSType = 0x4844_4E57 // "HDNW"

    @discardableResult
    func register(_ binding: Binding, handler: @escaping () -> Void) -> Bool {
        installIfNeeded()
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: binding.id)
        let status = RegisterEventHotKey(
            UInt32(binding.keyCode), UInt32(Self.modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs.append(ref)
        handlers[binding.id] = handler
        return true
    }

    fileprivate func fire(_ id: UInt32) {
        handlers[id]?()
    }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            if status == noErr {
                let id = hotKeyID.id
                DispatchQueue.main.async { HotKeys.shared.fire(id) }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
