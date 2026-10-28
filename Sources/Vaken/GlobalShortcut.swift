import AppKit
import Carbon
import VakenCore

final class GlobalShortcut {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var monitor: Any?
    var action: (() -> Void)?
    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<GlobalShortcut>.fromOpaque(userData).takeUnretainedValue()
            owner.action?()
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
    func register(_ shortcut: KeyboardShortcut?) -> String? {
        if let reference { UnregisterEventHotKey(reference); self.reference = nil }
        guard let shortcut else { return nil }
        guard handler != nil else { return "Keyboard shortcut handling is unavailable." }
        let id = EventHotKeyID(signature: 0x56414B4E, id: 1)
        let result = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &reference)
        return result == noErr ? nil : "That shortcut is unavailable or used by another app."
    }
    func cancelRecording() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
    func record(_ completion: @escaping (KeyboardShortcut?, String?) -> Void) {
        cancelRecording()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancelRecording(); completion(nil, nil); return nil }
            let f = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let count = [NSEvent.ModifierFlags.command, .option, .control, .shift].filter { f.contains($0) }.count
            guard count >= 2, f.contains(.command) || f.contains(.control) else {
                completion(nil, "Use Command or Control plus another modifier."); return nil
            }
            var modifiers: UInt32 = 0, prefix = ""
            if f.contains(.control) { modifiers |= UInt32(controlKey); prefix += "⌃" }
            if f.contains(.option) { modifiers |= UInt32(optionKey); prefix += "⌥" }
            if f.contains(.shift) { modifiers |= UInt32(shiftKey); prefix += "⇧" }
            if f.contains(.command) { modifiers |= UInt32(cmdKey); prefix += "⌘" }
            let key = event.keyCode == 49 ? "Space" : (event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)")
            self?.cancelRecording()
            completion(.init(keyCode: UInt32(event.keyCode), modifiers: modifiers, label: prefix + key), nil)
            return nil
        }
    }
}
