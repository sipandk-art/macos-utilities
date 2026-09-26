import Carbon

/// Глобальное сочетание клавиш через Carbon `RegisterEventHotKey`.
///
/// В отличие от перехвата клавиатуры, этот способ не требует никаких разрешений:
/// система сама сообщает приложению о нажатии именно этого сочетания и ничего
/// больше ему не показывает.
final class GlobalHotKey {

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    fileprivate let id: UInt32
    fileprivate let action: () -> Void

    private static var nextID: UInt32 = 1

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.id = Self.nextID
        Self.nextID += 1
        self.action = action

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            let hotkey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            guard pressed.id == hotkey.id else { return OSStatus(eventNotHandledErr) }
            hotkey.action()
            return noErr
        }, 1, &spec, me, &handlerRef)
        guard installed == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4D55_544C), id: id)   // "MUTL"
        guard RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(),
                                  0, &hotKeyRef) == noErr else {
            unregister()
            return nil
        }
    }

    func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        if let handler = handlerRef { RemoveEventHandler(handler); handlerRef = nil }
    }

    deinit { unregister() }
}
