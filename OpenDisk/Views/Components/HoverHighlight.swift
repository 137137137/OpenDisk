import SwiftUI

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
    func hoverHighlight(cornerRadius: CGFloat = 8, isEnabled: Bool = true) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius, isEnabled: isEnabled))
    }
}
