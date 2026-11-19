import Carbon.HIToolbox

/// System-wide shortcuts without needing accessibility access. Optional release action for hold-to-talk.
final class HotKeys {
    static let shared = HotKeys()
    private var actions: [UInt32: () -> Void] = [:]
    private var releases: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 1

    private init() {
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard status == noErr else { return noErr }
            if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
                HotKeys.shared.releases[hk.id]?()
            } else {
                HotKeys.shared.actions[hk.id]?()
            }
            return noErr
        }, 2, &specs, nil, &handler)
    }

    func register(keyCode: Int, modifiers: Int, onRelease: (() -> Void)? = nil, action: @escaping () -> Void) {
        let id = nextID
        nextID += 1
        actions[id] = action
        if let onRelease { releases[id] = onRelease }
        var ref: EventHotKeyRef?
        let hk = EventHotKeyID(signature: OSType(0x5354_4443), id: id)
        if RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hk, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
            refs.append(ref)
        }
    }
}
