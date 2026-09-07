import AppKit
import Carbon.HIToolbox

/// Global ⌃⌥Space shortcut that summons the island without touching the trackpad.
/// Uses Carbon's RegisterEventHotKey, which works for background apps with no permissions.
final class HotKeyService {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private static let signature: OSType = 0x4E4F5443 // "NOTC"

    func start() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKeyService.toggleIsland() }
            return noErr
        }, 1, &eventType, nil, &handlerRef)
        guard status == noErr else { return }
        let id = EventHotKeyID(signature: HotKeyService.signature, id: 1)
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func stop() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
    }

    static func toggleIsland() {
        let center = ActivityCenter.shared
        if center.presentation.isExpanded {
            center.collapse()
        } else if let primary = center.primary, primary.content.hasExpandedView {
            center.forceExpanded(id: primary.id, for: 8)
        } else {
            center.showHome(for: 8)
        }
    }
}
