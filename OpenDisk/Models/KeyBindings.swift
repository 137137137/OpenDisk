import AppKit
import Foundation
import Observation

enum KeyAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case moveDown
    case moveUp
    case openSelected
    case enclosingFolder
    case addToCollector
    case quickLook
    case showInFinder
    case selectAll

    var id: String { rawValue }

    var title: String {
        switch self {
        case .moveDown: "Next item"
        case .moveUp: "Previous item"
        case .openSelected: "Open folder / preview file"
        case .enclosingFolder: "Enclosing folder"
        case .addToCollector: "Add selection to collector"
        case .quickLook: "Quick Look"
        case .showInFinder: "Show in Finder"
        case .selectAll: "Select all"
        }
    }

    var detail: String {
        switch self {
        case .moveDown, .moveUp: "Hold ⇧ to extend the selection"
        case .openSelected: "Folders open in the list, files open in Quick Look"
        case .enclosingFolder: "Go up one level"
        case .addToCollector: "Queues the selected items for deletion"
        case .quickLook: "Toggles the preview for the selected item"
        case .showInFinder: "Reveals the selected items in Finder"
        case .selectAll: "Selects every item in the list"
        }
    }

    var defaultCombo: KeyCombo {
        switch self {
        case .moveDown: KeyCombo(keyCode: KeyCombo.Code.downArrow, modifiers: [])
        case .moveUp: KeyCombo(keyCode: KeyCombo.Code.upArrow, modifiers: [])
        case .openSelected: KeyCombo(keyCode: KeyCombo.Code.rightArrow, modifiers: [])
        case .enclosingFolder: KeyCombo(keyCode: KeyCombo.Code.leftArrow, modifiers: [])
        case .addToCollector: KeyCombo(keyCode: KeyCombo.Code.delete, modifiers: [.command])
        case .quickLook: KeyCombo(keyCode: KeyCombo.Code.space, modifiers: [])
        case .showInFinder: KeyCombo(keyCode: KeyCombo.Code.r, modifiers: [.command, .shift])
        case .selectAll: KeyCombo(keyCode: KeyCombo.Code.a, modifiers: [.command])
        }
    }
}

struct KeyCombo: Codable, Equatable, Hashable, Sendable {
    enum Code {
        static let a: UInt16 = 0
        static let r: UInt16 = 15
        static let returnKey: UInt16 = 36
        static let tab: UInt16 = 48
        static let space: UInt16 = 49
        static let delete: UInt16 = 51
        static let escape: UInt16 = 53
        static let enter: UInt16 = 76
        static let home: UInt16 = 115
        static let pageUp: UInt16 = 116
        static let forwardDelete: UInt16 = 117
        static let end: UInt16 = 119
        static let pageDown: UInt16 = 121
        static let leftArrow: UInt16 = 123
        static let rightArrow: UInt16 = 124
        static let downArrow: UInt16 = 125
        static let upArrow: UInt16 = 126
    }

    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    let keyCode: UInt16
    let modifierRawValue: UInt
    let keyLabel: String

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, keyLabel: String? = nil) {
        self.keyCode = keyCode
        self.modifierRawValue = modifiers.intersection(Self.relevantModifiers).rawValue
        self.keyLabel = keyLabel ?? Self.label(forKeyCode: keyCode) ?? ""
    }

    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        let typed = event.charactersIgnoringModifiers?.uppercased()
        let label = Self.specialLabel(forKeyCode: event.keyCode)
            ?? (typed?.isEmpty == false ? typed : Self.label(forKeyCode: event.keyCode))
        guard let label, !label.isEmpty else { return nil }
        self.init(keyCode: event.keyCode, modifiers: event.modifierFlags, keyLabel: label)
    }

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierRawValue) }

    var displayString: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + keyLabel
    }

    func matches(_ event: NSEvent, ignoringShift: Bool = false) -> Bool {
        guard event.keyCode == keyCode else { return false }
        var eventModifiers = event.modifierFlags.intersection(Self.relevantModifiers)
        var expected = modifiers
        if ignoringShift {
            eventModifiers.remove(.shift)
            expected.remove(.shift)
        }
        return eventModifiers == expected
    }

    static func label(forKeyCode code: UInt16) -> String? {
        specialLabel(forKeyCode: code) ?? ansiLabels[code]
    }

    static func specialLabel(forKeyCode code: UInt16) -> String? {
        switch code {
        case Code.returnKey: "↩"
        case Code.tab: "⇥"
        case Code.space: "Space"
        case Code.delete: "⌫"
        case Code.escape: "⎋"
        case Code.enter: "⌤"
        case Code.home: "↖"
        case Code.pageUp: "⇞"
        case Code.forwardDelete: "⌦"
        case Code.end: "↘"
        case Code.pageDown: "⇟"
        case Code.leftArrow: "←"
        case Code.rightArrow: "→"
        case Code.downArrow: "↓"
        case Code.upArrow: "↑"
        default: nil
        }
    }

    private static let ansiLabels: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
        20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
        29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J",
        39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
        50: "`",
    ]
}

@MainActor
@Observable
final class KeyBindingStore {
    static let shared = KeyBindingStore()
    static let defaultsKey = "key_bindings"

    struct Match: Equatable {
        let action: KeyAction
        let extendsSelection: Bool
    }

    private(set) var bindings: [KeyAction: KeyCombo]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var loaded: [KeyAction: KeyCombo] = [:]
        if let data = defaults.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode([String: KeyCombo].self, from: data) {
            for (key, combo) in stored {
                if let action = KeyAction(rawValue: key) { loaded[action] = combo }
            }
        }
        bindings = loaded
    }

    func combo(for action: KeyAction) -> KeyCombo? {
        bindings[action] ?? (isUnbound(action) ? nil : action.defaultCombo)
    }

    func isDefault(_ action: KeyAction) -> Bool {
        combo(for: action) == action.defaultCombo
    }

    func isUnbound(_ action: KeyAction) -> Bool {
        unboundActions.contains(action)
    }

    private var unboundActions: Set<KeyAction> {
        get {
            Set((defaults.array(forKey: Self.defaultsKey + "_unbound") as? [String] ?? [])
                .compactMap(KeyAction.init(rawValue:)))
        }
        set {
            defaults.set(newValue.map(\.rawValue).sorted(), forKey: Self.defaultsKey + "_unbound")
        }
    }

    @discardableResult
    func set(_ combo: KeyCombo, for action: KeyAction) -> KeyAction? {
        var displaced: KeyAction?
        for other in KeyAction.allCases where other != action {
            if self.combo(for: other) == combo {
                displaced = other
                bindings[other] = nil
                unboundActions.insert(other)
            }
        }
        bindings[action] = combo
        unboundActions.remove(action)
        persist()
        return displaced
    }

    func reset(_ action: KeyAction) {
        for other in KeyAction.allCases where other != action {
            if combo(for: other) == action.defaultCombo {
                bindings[other] = nil
                unboundActions.insert(other)
            }
        }
        bindings[action] = nil
        unboundActions.remove(action)
        persist()
    }

    func resetAll() {
        bindings = [:]
        unboundActions = []
        persist()
    }

    func match(_ event: NSEvent) -> Match? {
        for action in KeyAction.allCases {
            if let combo = combo(for: action), combo.matches(event) {
                return Match(action: action, extendsSelection: false)
            }
        }
        for action in [KeyAction.moveDown, .moveUp] {
            if let combo = combo(for: action), !combo.modifiers.contains(.shift),
               combo.matches(event, ignoringShift: true),
               event.modifierFlags.contains(.shift) {
                return Match(action: action, extendsSelection: true)
            }
        }
        return nil
    }

    private func persist() {
        var stored: [String: KeyCombo] = [:]
        for (action, combo) in bindings { stored[action.rawValue] = combo }
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
