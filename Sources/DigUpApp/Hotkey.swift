import AppKit
import Carbon.HIToolbox

/// A key combination like "cmd+shift+space", as written in defaults (`hotkey`) or on the command line.
nonisolated struct KeyCombo: Equatable, Sendable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let display: String   // "⇧⌘Space"
    /// "cmd+shift+space": how it's saved.
    let spec: String
    /// The keycaps, in order: ["⇧", "⌘", "Space"].
    let caps: [String]

    private static let keys: [String: (code: Int, name: String)] = {
        var keys: [String: (Int, String)] = [
            "space": (kVK_Space, "Space"), "return": (kVK_Return, "↩"), "tab": (kVK_Tab, "⇥"),
            "escape": (kVK_Escape, "⎋"), "esc": (kVK_Escape, "⎋"), "slash": (kVK_ANSI_Slash, "/"),
            "period": (kVK_ANSI_Period, "."), "comma": (kVK_ANSI_Comma, ","), "semicolon": (kVK_ANSI_Semicolon, ";"),
            "quote": (kVK_ANSI_Quote, "'"), "backslash": (kVK_ANSI_Backslash, "\\"), "grave": (kVK_ANSI_Grave, "`"),
            "minus": (kVK_ANSI_Minus, "-"), "equal": (kVK_ANSI_Equal, "="),
        ]
        let letters: [(String, Int)] = [
            ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D), ("e", kVK_ANSI_E),
            ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H), ("i", kVK_ANSI_I), ("j", kVK_ANSI_J),
            ("k", kVK_ANSI_K), ("l", kVK_ANSI_L), ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O),
            ("p", kVK_ANSI_P), ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
            ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X), ("y", kVK_ANSI_Y),
            ("z", kVK_ANSI_Z), ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3),
            ("4", kVK_ANSI_4), ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7), ("8", kVK_ANSI_8),
            ("9", kVK_ANSI_9),
        ]
        for (letter, code) in letters { keys[letter] = (code, letter.uppercased()) }
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                            kVK_F11, kVK_F12]
        for (index, code) in functionKeys.enumerated() { keys["f\(index + 1)"] = (code, "F\(index + 1)") }
        return keys
    }()

    /// Parses "cmd+shift+space", "opt+space", "ctrl+opt+f"… Modifier names: cmd, shift, opt (alt), ctrl.
    init?(_ text: String) {
        var modifiers: UInt32 = 0
        var key: (code: Int, name: String)?
        for part in text.lowercased().split(whereSeparator: { $0 == "+" || $0 == "-" || $0 == " " }) {
            switch part {
            case "cmd", "command", "⌘": modifiers |= UInt32(cmdKey)
            case "shift", "⇧": modifiers |= UInt32(shiftKey)
            case "opt", "option", "alt", "⌥": modifiers |= UInt32(optionKey)
            case "ctrl", "control", "⌃": modifiers |= UInt32(controlKey)
            default:
                guard key == nil, let found = Self.keys[String(part)] else { return nil }
                key = found
            }
        }
        guard let key else { return nil }
        self.init(code: key.code, modifiers: modifiers)
    }

    /// From a key press (the shortcut recorder). Nil for keys it can't name, or without ⌘, ⌥ or ⌃ (only F-keys may go
    /// without; ⇧ alone would take a letter away from typing everywhere).
    init?(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        self.init(code: Int(keyCode), modifiers: modifiers)
    }

    private init?(code: Int, modifiers: UInt32) {
        guard let name = Self.names[code] else { return nil }
        let isFunctionKey = name.display.count > 1 && name.display.hasPrefix("F")
        guard modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 || isFunctionKey else { return nil }
        keyCode = UInt32(code)
        carbonModifiers = modifiers
        var caps: [String] = [], parts: [String] = []
        for (mask, symbol, word) in [(controlKey, "⌃", "ctrl"), (optionKey, "⌥", "opt"), (shiftKey, "⇧", "shift"),
                                     (cmdKey, "⌘", "cmd")] where modifiers & UInt32(mask) != 0 {
            caps.append(symbol)
            parts.append(word)
        }
        self.caps = caps + [name.display]
        display = caps.joined() + name.display
        spec = (parts + [name.spec]).joined(separator: "+")
    }

    /// Key code → its name in a spec ("space") and on a keycap ("Space").
    private static let names: [Int: (spec: String, display: String)] = {
        var names: [Int: (String, String)] = [:]
        for (spec, key) in keys.sorted(by: { $0.key.count > $1.key.count }) {   // "escape" wins over "esc"
            if names[key.code] == nil { names[key.code] = (spec, key.name) }
        }
        return names
    }()

    /// The macOS shortcut this combination would collide with, if it's one that's switched on (System Settings →
    /// Keyboard → Keyboard Shortcuts): macOS gets those keys first, so a hotkey there would never fire.
    var systemConflict: String? {
        var list: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&list) == noErr,
              let entries = list?.takeRetainedValue() as? [[String: Any]] else { return nil }
        let taken = entries.contains { entry in
            (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true
                && (entry[kHISymbolicHotKeyCode as String] as? Int) == Int(keyCode)
                && (entry[kHISymbolicHotKeyModifiers as String] as? Int).map { UInt32($0) & 0xFF00 } == carbonModifiers
        }
        guard taken else { return nil }
        switch (Int(keyCode), Int(carbonModifiers)) {
        case (kVK_Space, cmdKey): return "Spotlight uses \(display)"
        case (kVK_Space, cmdKey | optionKey): return "Finder's search window uses \(display)"
        case (kVK_Space, controlKey), (kVK_Space, controlKey | optionKey): return "Switching input sources uses \(display)"
        case (kVK_Space, controlKey | cmdKey): return "The emoji picker uses \(display)"
        case (kVK_ANSI_3, cmdKey | shiftKey), (kVK_ANSI_4, cmdKey | shiftKey), (kVK_ANSI_5, cmdKey | shiftKey):
            return "Screenshots use \(display)"
        default: return "macOS uses \(display) for one of its shortcuts"
        }
    }
}

extension KeyCombo {
    /// The combo as an NSMenuItem key equivalent, so the menu shows it next to Search….
    var menuEquivalent: (String, NSEvent.ModifierFlags)? {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        let name = display.trimmingCharacters(in: CharacterSet(charactersIn: "⌃⌥⇧⌘"))
        switch name {
        case "Space": return (" ", flags)
        case _ where name.count == 1: return (name.lowercased(), flags)
        default: return nil
        }
    }
}

/// The app's one hotkey: registers it, swaps it for a new one (keeping the old one if the new one is taken), and
/// steps aside while the shortcut recorder listens, so pressing the current combination reaches the recorder.
final class HotkeyCenter {
    private var hotkey: GlobalHotkey?
    private(set) var combo: KeyCombo?
    /// The recorder is listening: nothing is registered, and `resume()` brings `combo` back.
    private var isSuspended = false
    var onPress: () -> Void = {}

    /// Registers `combo` in place of the current one. On failure (another app has it) the current one stays.
    @discardableResult
    func register(_ combo: KeyCombo) -> Bool {
        if combo == self.combo, hotkey != nil { return true }
        let previous = hotkey
        hotkey = nil   // the old registration goes first, in case the new one is the same keys
        guard let new = make(combo) else {
            hotkey = previous
            return false
        }
        hotkey = new
        self.combo = combo
        isSuspended = false
        return true
    }

    func suspend() {
        guard hotkey != nil else { return }
        isSuspended = true
        hotkey = nil
    }

    func resume() {
        guard isSuspended, let combo else { return }
        isSuspended = false
        hotkey = make(combo)
    }

    private func make(_ combo: KeyCombo) -> GlobalHotkey? {
        GlobalHotkey(combo, action: { [weak self] in self?.onPress() })
    }
}

/// A system-wide hotkey through Carbon's `RegisterEventHotKey`, which needs no Accessibility permission.
final class GlobalHotkey {
    let combo: KeyCombo
    private let action: () -> Void
    nonisolated(unsafe) private var hotKey: EventHotKeyRef?   // touched only on the main thread and in deinit
    nonisolated(unsafe) private var handler: EventHandlerRef?

    /// Nil when the combination can't be registered (another app may own it).
    init?(_ combo: KeyCombo, action: @escaping () -> Void) {
        self.combo = combo
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard InstallEventHandler(GetApplicationEventTarget(), hotkeyPressed, 1, &spec, me, &handler) == noErr else {
            return nil
        }
        let id = EventHotKeyID(signature: OSType(0x4447_5550), id: 1)   // "DGUP"
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, id, GetApplicationEventTarget(), 0,
                                         &hotKey)
        guard status == noErr else {
            if let handler { RemoveEventHandler(handler) }
            handler = nil   // deinit runs too, and must not remove it a second time
            return nil
        }
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }

    fileprivate func fire() { action() }
}

/// Carbon delivers hotkey events on the main thread.
private nonisolated func hotkeyPressed(_ next: EventHandlerCallRef?, _ event: EventRef?,
                                       _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let address = UInt(bitPattern: userData)
    MainActor.assumeIsolated {
        let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(UnsafeRawPointer(bitPattern: address)!).takeUnretainedValue()
        hotkey.fire()
    }
    return noErr
}
