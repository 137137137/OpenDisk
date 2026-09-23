import SwiftUI

enum ChartPalette {
    struct RGB: Equatable {
        var red: Double
        var green: Double
        var blue: Double

        var color: Color { Color(red: red, green: green, blue: blue) }
    }

    static let hues: [RGB] = [
        RGB(red: 0xE0 / 255.0, green: 0x1B / 255.0, blue: 0x24 / 255.0),
        RGB(red: 0xFF / 255.0, green: 0x78 / 255.0, blue: 0x00 / 255.0),
        RGB(red: 0xF6 / 255.0, green: 0xD3 / 255.0, blue: 0x2D / 255.0),
        RGB(red: 0x33 / 255.0, green: 0xD1 / 255.0, blue: 0x7A / 255.0),
        RGB(red: 0x35 / 255.0, green: 0x84 / 255.0, blue: 0xE4 / 255.0),
        RGB(red: 0x91 / 255.0, green: 0x41 / 255.0, blue: 0xAC / 255.0),
    ]

    static let level = RGB(red: 0xD3 / 255.0, green: 0xD6 / 255.0, blue: 0xD1 / 255.0)
    static let levelHighlighted = RGB(red: 0xE0 / 255.0, green: 0xE2 / 255.0, blue: 0xDD / 255.0)

    private static let bandWidth = 100.0 / 3.0

    static func fill(position: Double, depth: Int, highlighted: Bool) -> RGB {
        guard depth > 0 else { return highlighted ? levelHighlighted : level }

        let clamped = position.isFinite ? min(max(position, 0), 199.999) : 0
        let band = Int(clamped / bandWidth)
        let t = (clamped - Double(band) * bandWidth) / bandWidth
        let from = hues[band % hues.count]
        let to = hues[(band + 1) % hues.count]
        var rgb = RGB(
            red: from.red + (to.red - from.red) * t,
            green: from.green + (to.green - from.green) * t,
            blue: from.blue + (to.blue - from.blue) * t
        )

        let intensity = 1.0 - (Double(depth - 1) * 0.3) / 5.0
        rgb.red *= intensity
        rgb.green *= intensity
        rgb.blue *= intensity

        if highlighted {
            let peak = max(rgb.red, max(rgb.green, rgb.blue))
            if peak > 0 {
                rgb.red /= peak
                rgb.green /= peak
                rgb.blue /= peak
            }
        }
        return rgb
    }
}
