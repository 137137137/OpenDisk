import Foundation

enum ByteFormatter {
    private static let fileFormatter = Mutex<ByteCountFormatter>({
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        return formatter
    }())

    private static let decimalNoFractionFormatter = Mutex<ByteCountFormatter>({
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        formatter.allowsNonnumericFormatting = false
        formatter.zeroPadsFractionDigits = false
        formatter.allowedUnits = [.useGB, .useTB]
        return formatter
    }())

    static func formatFileSize(_ bytes: Int64) -> String {
        fileFormatter.withLock { $0.string(fromByteCount: bytes) }
    }

    static func formatCapacity(_ bytes: Int64) -> String {
        bytes >= 1_000_000_000 || bytes <= 0
            ? formatDecimalNoFraction(max(bytes, 0))
            : formatFileSize(bytes)
    }

    static func formatDecimalNoFraction(_ bytes: Int64) -> String {
        let formatted = decimalNoFractionFormatter.withLock { $0.string(fromByteCount: bytes) }
        if let range = formatted.range(of: "[.,]\\d+", options: .regularExpression) {
            return String(formatted[..<range.lowerBound] + formatted[range.upperBound...])
        }
        return formatted
    }
}

enum DurationFormatter {
    static func scanDuration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return String(format: "Scanned in %.0f ms", duration * 1_000)
        }
        if duration < 60 {
            return String(format: "Scanned in %.1f seconds", duration)
        }
        let total = Int(duration.rounded())
        let hours = total / 3_600
        let minutes = total % 3_600 / 60
        if hours > 0 {
            return "Scanned in \(hours) hr \(minutes) min"
        }
        return "Scanned in \(minutes) min \(total % 60) sec"
    }
}
