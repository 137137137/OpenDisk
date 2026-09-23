import Foundation
import Synchronization

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
        let minutes = Int(duration / 60)
        let seconds = Int(duration.truncatingRemainder(dividingBy: 60))
        return String(format: "Scanned in %d:%02d", minutes, seconds)
    }
}
