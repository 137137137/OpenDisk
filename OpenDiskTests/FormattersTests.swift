import Foundation
import Testing
@testable import OpenDisk

@Suite("Formatters")
struct FormattersTests {
    @Test("file sizes pick sensible units")
    func fileSizes() {
        #expect(ByteFormatter.formatFileSize(0).hasPrefix("Zero"))
        #expect(ByteFormatter.formatFileSize(1_024) == "1 KB")
        #expect(ByteFormatter.formatFileSize(1_024 * 1_024) == "1 MB")
        #expect(ByteFormatter.formatFileSize(1_024 * 1_024 * 1_024).hasSuffix("GB"))
    }

    @Test("device capacities drop fractions")
    func decimalNoFraction() {
        #expect(!ByteFormatter.formatDecimalNoFraction(500_000_000_000).contains("."))
        #expect(!ByteFormatter.formatDecimalNoFraction(1_500_000_000_000).contains("."))
    }

    @Test("capacities stay whole from 1 GB up and fall back to smaller units below")
    func capacities() {
        #expect(ByteFormatter.formatCapacity(175_400_000_000) == ByteFormatter.formatDecimalNoFraction(175_400_000_000))
        #expect(ByteFormatter.formatCapacity(400_000_000).hasSuffix("MB"))
        #expect(!ByteFormatter.formatCapacity(0).hasPrefix("Zero"))
    }

    @Test("scan durations pick sensible units", arguments: [
        (0.5, "ms"), (3.2, "seconds"), (65.0, "1 min, 5 sec"), (3_725.0, "1 hr, 2 min"),
    ])
    func durations(duration: Double, expectedFragment: String) {
        #expect(DurationFormatter.scanDuration(duration).contains(expectedFragment))
    }
}
