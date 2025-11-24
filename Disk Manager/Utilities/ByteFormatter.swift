import Foundation

/// A utility class for consistent byte size formatting across the application
enum ByteFormatter {

    /// Formats byte size for file system display (e.g., "2.5 GB")
    static func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        return formatter.string(fromByteCount: bytes)
    }

    /// Formats byte size for decimal display without fractions (e.g., "2 GB")
    static func formatDecimalNoFraction(_ bytes: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        formatter.allowsNonnumericFormatting = false
        formatter.includesCount = true
        formatter.includesUnit = true
        formatter.zeroPadsFractionDigits = false
        formatter.allowedUnits = [.useGB, .useTB]
        formatter.formattingContext = .standalone

        let formattedString = formatter.string(fromByteCount: Int64(bytes))

        // Remove decimal portion for cleaner display
        if let range = formattedString.range(of: "\\.\\d+", options: .regularExpression) {
            return String(formattedString[..<range.lowerBound] + formattedString[range.upperBound...])
        }

        return formattedString
    }

    /// Simple decimal formatting with default settings
    static func formatDecimal(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        return formatter.string(fromByteCount: bytes)
    }
}