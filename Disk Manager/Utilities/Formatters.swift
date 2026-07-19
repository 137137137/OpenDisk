import Foundation

/// Byte-size formatting used across the app.
///
/// Formatter construction is expensive and these run per visible row per
/// render (and in chart labels), so each configuration is built once.
/// `ByteCountFormatter.string(fromByteCount:)` is thread-safe for these
/// main-thread-only call sites.
enum ByteFormatter {

    private static let fileFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        return formatter
    }()

    private static let decimalNoFractionFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        formatter.allowsNonnumericFormatting = false
        formatter.zeroPadsFractionDigits = false
        formatter.allowedUnits = [.useGB, .useTB]
        return formatter
    }()

    /// File-style size, e.g. "2.5 GB".
    static func formatFileSize(_ bytes: Int64) -> String {
        fileFormatter.string(fromByteCount: bytes)
    }

    /// Decimal size without fractions, e.g. "500 GB" — used for device
    /// capacities in the sidebar.
    static func formatDecimalNoFraction(_ bytes: Int64) -> String {
        let formatted = decimalNoFractionFormatter.string(fromByteCount: bytes)
        // ByteCountFormatter offers no fraction-digit control; strip the
        // fraction for the compact sidebar figures. Match either decimal
        // separator so comma-decimal locales strip too.
        if let range = formatted.range(of: "[.,]\\d+", options: .regularExpression) {
            return String(formatted[..<range.lowerBound] + formatted[range.upperBound...])
        }
        return formatted
    }
}

/// Time-interval formatting for scan durations.
enum DurationFormatter {

    /// e.g. "Scanned in 3.2 seconds" / "Scanned in 1:05".
    static func scanDuration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return String(format: "Scanned in %.0f ms", duration * 1_000)
        }
        if duration < 60 {
            return String(format: "Scanned in %.1f seconds", duration)
        }
        let minutes = Int(duration / 60)
        let seconds = Int(duration.truncatingRemainder(dividingBy: 60))
        return String(format: "Scanned in %d:%02d", minutes, seconds)
    }
}
