import SwiftUI

/// The app's shared hover treatment for clickable rows: a quaternary
/// rounded-rectangle wash faded in and out. Owns its own hover state so
/// hovering never invalidates the containing view.
private struct HoverHighlight: ViewModifier {
    var cornerRadius: CGFloat
    var isEnabled: Bool

    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background {
                if isHovered && isEnabled {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.quaternary)
                }
            }
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovered = hovering
                }
            }
    }
}

extension View {
    /// Applies the standard hover-highlight row treatment.
    func hoverHighlight(cornerRadius: CGFloat = 8, isEnabled: Bool = true) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius, isEnabled: isEnabled))
    }
}
