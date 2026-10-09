import AppKit
import SwiftUI

struct ShortcutRecorder: View {
    let action: KeyAction
    let store: KeyBindingStore

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var displacedTitle: String?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggleRecording) {
                Text(label)
                    .font(.system(.body, design: .rounded))
                    .monospacedDigit()
                    .frame(minWidth: 72)
                    .foregroundStyle(labelColor)
            }
            .buttonStyle(.bordered)
            .help(isRecording ? "Press the new shortcut, or ⎋ to cancel" : "Click to change")

            Button {
                store.reset(action)
                displacedTitle = nil
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .help("Restore default (\(action.defaultCombo.displayString))")
            .opacity(store.isDefault(action) ? 0 : 1)
            .disabled(store.isDefault(action))
        }
        .onDisappear(perform: stopRecording)
    }

    private var label: String {
        if isRecording { return "Press keys…" }
        return store.combo(for: action)?.displayString ?? "None"
    }

    private var labelColor: Color {
        if isRecording { return .accentColor }
        return store.combo(for: action) == nil ? .orange : .primary
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == KeyCombo.Code.escape
                && event.modifierFlags.intersection(KeyCombo.relevantModifiers).isEmpty {
                stopRecording()
                return nil
            }
            guard let combo = KeyCombo(event: event) else { return nil }
            displacedTitle = store.set(combo, for: action)?.title
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }
}
