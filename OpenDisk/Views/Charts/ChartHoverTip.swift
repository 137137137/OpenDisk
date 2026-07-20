import SwiftUI

/// Draws the baobab-style hover tip (dark pill with name, size and share)
/// directly into a chart's `Canvas`.
///
/// Rendered with `GraphicsContext` on purpose: the tip follows the pointer
/// on every hover event, and as a SwiftUI overlay each move would
/// participate in layout — which visibly shifted the whole chart around.
/// Inside the canvas it can only ever trigger a repaint.
enum ChartTipRenderer {

    private static let padding = CGSize(width: 8, height: 5)
    private static let pointerOffset = CGPoint(x: 14, y: -28)

    static func draw(
        name: String,
        size: Int64,
        fractionOfRoot: Double,
        near location: CGPoint,
        in context: inout GraphicsContext,
        bounds: CGSize
    ) {
        let title = context.resolve(
            Text(name).font(.caption).fontWeight(.semibold)
                .foregroundStyle(.white)
        )
        let percent = String(format: "%.1f", fractionOfRoot * 100)
        let detail = context.resolve(
            Text("\(ByteFormatter.formatFileSize(size)) · \(percent)%")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.85))
        )

        let maxTextWidth = min(280, bounds.width - padding.width * 2)
        let titleSize = title.measure(in: CGSize(width: maxTextWidth, height: 40))
        let detailSize = detail.measure(in: CGSize(width: maxTextWidth, height: 40))
        let pill = CGSize(
            width: max(titleSize.width, detailSize.width) + padding.width * 2,
            height: titleSize.height + detailSize.height + 2 + padding.height * 2
        )

        // Beside the pointer, flipped or clamped when it would leave the
        // canvas.
        var origin = CGPoint(
            x: location.x + pointerOffset.x,
            y: location.y + pointerOffset.y - pill.height / 2
        )
        if origin.x + pill.width > bounds.width - 4 {
            origin.x = location.x - pointerOffset.x - pill.width
        }
        origin.x = min(max(origin.x, 4), max(bounds.width - pill.width - 4, 4))
        origin.y = min(max(origin.y, 4), max(bounds.height - pill.height - 4, 4))

        let rect = CGRect(origin: origin, size: pill)
        context.fill(
            Path(roundedRect: rect, cornerRadius: 6, style: .continuous),
            with: .color(.black.opacity(0.8))
        )
        context.draw(title, at: CGPoint(
            x: rect.minX + padding.width + titleSize.width / 2,
            y: rect.minY + padding.height + titleSize.height / 2
        ))
        context.draw(detail, at: CGPoint(
            x: rect.minX + padding.width + detailSize.width / 2,
            y: rect.minY + padding.height + titleSize.height + 2 + detailSize.height / 2
        ))
    }
}
