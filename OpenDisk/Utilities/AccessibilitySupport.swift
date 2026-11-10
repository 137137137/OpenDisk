import AppKit
import SwiftUI

enum A11y {
    @MainActor
    static func announce(_ message: String) {
        guard !message.isEmpty else { return }
        AccessibilityNotification.Announcement(message).post()
    }

    @MainActor
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

extension Animation {
    static func unlessReducingMotion(_ animation: Animation, _ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

private struct InformativeTertiary: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.foregroundStyle(
            contrast == .increased ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary)
        )
    }
}

extension View {
    func informativeTertiary() -> some View {
        modifier(InformativeTertiary())
    }
}
