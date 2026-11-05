import AppKit
import Carbon.HIToolbox

/// Raccourci global ⌃⌥⌘G : met GHOST en pause (ou le reprend) immédiatement, depuis n'importe quelle application.
/// `RegisterEventHotKey` n'exige aucune permission.
@MainActor
final class GhostHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    nonisolated(unsafe) private static var action: (@MainActor () -> Void)?

    init(action: @escaping @MainActor () -> Void) {
        Self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Task { @MainActor in GhostHotKey.action?() }
            return noErr
        }, 1, &spec, nil, &handlerRef)
        let id = EventHotKeyID(signature: OSType(0x4748_4F53), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_G), UInt32(controlKey | optionKey | cmdKey), id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
