import AppKit
import Carbon.HIToolbox

/// The keys both search surfaces share, in one place: the key codes (named, from the same Carbon constants
/// `KeyCombo`'s name↔code table uses) and the normalization both handlers did (the input-method check and the
/// modifier-mask cleanup). Each surface keeps its own extra keys (the panel's ⌘O, the window's ⌘1…⌘7) and its
/// own selection movement, but reads every event through here.
enum KeyCommands {
    /// A key press, normalized: the raw code plus the modifiers the user actually held.
    struct Press {
        let keyCode: Int
        let modifiers: NSEvent.ModifierFlags
    }

    /// The event as a normalized `Press`, or nil while an input method is composing (Japanese, Chinese…): until
    /// it's done, ↩ and the arrows are its keys, not ours.
    static func press(_ event: NSEvent, field: NSTextField?) -> Press? {
        if (field?.currentEditor() as? NSTextView)?.hasMarkedText() == true { return nil }
        return Press(keyCode: Int(event.keyCode),
                     modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                         .subtracting([.capsLock, .numericPad, .function]))
    }

    // The named key codes both handlers switch on.
    static let escape = Int(kVK_Escape)
    static let enter = Int(kVK_Return)
    static let keypadEnter = Int(kVK_ANSI_KeypadEnter)
    static let space = Int(kVK_Space)
    static let leftArrow = Int(kVK_ANSI_LeftArrow)
    static let rightArrow = Int(kVK_ANSI_RightArrow)
    static let upArrow = Int(kVK_ANSI_UpArrow)
    static let downArrow = Int(kVK_ANSI_DownArrow)
    static let c = Int(kVK_ANSI_C)
    static let o = Int(kVK_ANSI_O)
    static let y = Int(kVK_ANSI_Y)
    /// The key codes of 1…6, in order (⌘1…⌘6 pick a result kind) — the same named Carbon constants
    /// `KeyCombo`'s name↔code table is built from, not a second copy of the raw numbers.
    static let numberKeys: [Int] = [Int(kVK_ANSI_1), Int(kVK_ANSI_2), Int(kVK_ANSI_3),
                                    Int(kVK_ANSI_4), Int(kVK_ANSI_5), Int(kVK_ANSI_6)]
    static let seven = Int(kVK_ANSI_7)
}
