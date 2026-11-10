import AppKit
import Foundation
import Testing
@testable import OpenDisk

@Suite("Key bindings")
@MainActor
struct KeyBindingsTests {
    private func makeStore() -> KeyBindingStore {
        let suite = UserDefaults(suiteName: "KeyBindingsTests-\(UUID().uuidString)")!
        suite.removePersistentDomain(forName: "KeyBindingsTests")
        return KeyBindingStore(defaults: suite)
    }

    private func keyEvent(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: code
        )!
    }

    @Test("defaults match arrow keys and shift extends vertical moves")
    func defaults() {
        let store = makeStore()
        #expect(store.match(keyEvent(KeyCombo.Code.downArrow))?.action == .moveDown)
        let extended = store.match(keyEvent(KeyCombo.Code.downArrow, .shift))
        #expect(extended?.action == .moveDown)
        #expect(extended?.extendsSelection == true)
        #expect(store.match(keyEvent(KeyCombo.Code.delete, .command))?.action == .addToCollector)
        #expect(store.match(keyEvent(KeyCombo.Code.delete)) == nil)
    }

    @Test("rebinding displaces a conflicting action and persists")
    func rebinding() {
        let store = makeStore()
        let combo = KeyCombo(keyCode: KeyCombo.Code.rightArrow, modifiers: [])
        let displaced = store.set(combo, for: .quickLook)
        #expect(displaced == .openSelected)
        #expect(store.combo(for: .openSelected) == nil)
        #expect(store.match(keyEvent(KeyCombo.Code.rightArrow))?.action == .quickLook)

        store.reset(.openSelected)
        #expect(store.combo(for: .openSelected) == KeyAction.openSelected.defaultCombo)
        #expect(store.combo(for: .quickLook) == nil)

        store.resetAll()
        #expect(store.combo(for: .quickLook) == KeyAction.quickLook.defaultCombo)
    }

    @Test("letter shortcuts follow the keyboard layout, not the physical key")
    func layoutAwareLetters() {
        let selectAll = KeyAction.selectAll.defaultCombo
        #expect(!selectAll.matches(keyCode: KeyCombo.Code.a, modifiers: .command, typedKeys: ["Q"]))
        #expect(selectAll.matches(keyCode: 12, modifiers: .command, typedKeys: ["A"]))
        #expect(selectAll.matches(keyCode: KeyCombo.Code.a, modifiers: .command, typedKeys: ["A"]))
        #expect(selectAll.matches(keyCode: KeyCombo.Code.a, modifiers: .command, typedKeys: []))
        #expect(!selectAll.matches(keyCode: 12, modifiers: .command, typedKeys: []))
        #expect(!selectAll.matches(keyCode: 12, modifiers: [], typedKeys: ["A"]))

        let legacyShifted = KeyCombo(keyCode: 18, modifiers: [.command, .shift], keyLabel: "!")
        #expect(legacyShifted.matches(keyCode: 18, modifiers: [.command, .shift], typedKeys: ["1", "!"]))

        let cyrillic = KeyCombo(keyCode: KeyCombo.Code.a, modifiers: [], keyLabel: "Ф")
        #expect(cyrillic.matches(keyCode: KeyCombo.Code.a, modifiers: [], typedKeys: []))

        let arrow = KeyAction.moveDown.defaultCombo
        #expect(arrow.matches(keyCode: KeyCombo.Code.downArrow, modifiers: [], typedKeys: []))
        #expect(!arrow.matches(keyCode: KeyCombo.Code.a, modifiers: [], typedKeys: ["A"]))
    }

    @Test("command letter shortcuts are left to the system, other keys stay with the key monitor")
    func systemHandled() {
        #expect(KeyAction.selectAll.defaultCombo.systemKey == "a")
        #expect(KeyAction.showInFinder.defaultCombo.systemKey == "r")
        #expect(KeyAction.addToCollector.defaultCombo.systemKey == nil)
        #expect(KeyAction.moveDown.defaultCombo.systemKey == nil)
        #expect(KeyCombo(keyCode: KeyCombo.Code.a, modifiers: [], keyLabel: "A").systemKey == nil)
        #expect(KeyCombo(keyCode: KeyCombo.Code.r, modifiers: .command, keyLabel: "R").systemKey == nil)
        #expect(KeyCombo(keyCode: 18, modifiers: [.command, .shift], keyLabel: "!").systemKey == nil)

        let store = makeStore()
        let event = keyEvent(KeyCombo.Code.r, [.command, .shift])
        #expect(store.match(event)?.action == .showInFinder)
        #expect(store.match(event, includingSystemHandled: false) == nil)
        #expect(store.match(keyEvent(KeyCombo.Code.delete, .command), includingSystemHandled: false)?.action == .addToCollector)
    }

    @Test("display strings use macOS glyphs")
    func display() {
        #expect(KeyAction.addToCollector.defaultCombo.displayString == "⌘⌫")
        #expect(KeyAction.showInFinder.defaultCombo.displayString == "⇧⌘R")
        #expect(KeyAction.quickLook.defaultCombo.displayString == "Space")
    }
}
