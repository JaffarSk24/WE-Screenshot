import Foundation

/// A global keyboard shortcut: a virtual key code plus modifier keys.
/// The shape is fixed; display names live in KeyComboDisplay.swift.
public struct KeyCombo: Codable, Equatable, Hashable, Sendable {
    public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        // The raw values are the Carbon modifier masks (cmdKey, shiftKey,
        // optionKey, controlKey), so rawValue can go to RegisterEventHotKey as is.
        public static let command = Modifiers(rawValue: 0x0100)
        public static let shift = Modifiers(rawValue: 0x0200)
        public static let option = Modifiers(rawValue: 0x0800)
        public static let control = Modifiers(rawValue: 0x1000)
    }

    /// Virtual key code (kVK_...), independent of the keyboard layout.
    public var keyCode: UInt32
    public var modifiers: Modifiers

    public init(keyCode: UInt32, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Modifier mask in the form RegisterEventHotKey expects.
    public var carbonModifiers: UInt32 { modifiers.rawValue }

    /// Shift+Command+9.
    public static let defaultCapture = KeyCombo(keyCode: 25, modifiers: [.command, .shift])
}
