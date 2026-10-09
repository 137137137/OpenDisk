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

    @Test("display strings use macOS glyphs")
    func display() {
        #expect(KeyAction.addToCollector.defaultCombo.displayString == "⌘⌫")
        #expect(KeyAction.showInFinder.defaultCombo.displayString == "⇧⌘R")
        #expect(KeyAction.quickLook.defaultCombo.displayString == "Space")
    }
}
