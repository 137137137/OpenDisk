import Foundation
import Testing
@testable import Disk_Manager

@Suite("Formatters")
struct FormattersTests {

    @Test("file sizes use binary-style file formatting")
    func fileSizes() {
        #expect(ByteFormatter.formatFileSize(0) == "Zero KB")
        #expect(ByteFormatter.formatFileSize(1_024) == "1 KB")
        #expect(ByteFormatter.formatFileSize(1_024 * 1_024) == "1 MB")
        #expect(ByteFormatter.formatFileSize(1_024 * 1_024 * 1_024) == "1 GB")
    }

    @Test("device capacities drop fractions")
    func decimalNoFraction() {
        #expect(!ByteFormatter.formatDecimalNoFraction(500_000_000_000).contains("."))
        #expect(!ByteFormatter.formatDecimalNoFraction(1_500_000_000_000).contains("."))
    }

    @Test("scan durations pick sensible units", arguments: [
        (0.5, "ms"), (3.2, "seconds"), (65.0, "1:05"),
    ])
    func durations(duration: Double, expectedFragment: String) {
        #expect(DurationFormatter.scanDuration(duration).contains(expectedFragment))
    }
}
