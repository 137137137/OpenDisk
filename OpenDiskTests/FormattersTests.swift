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

    @Test("permissions render like ls -l", arguments: [
        (UInt16(0o755), "rwxr-xr-x"),
        (UInt16(0o644), "rw-r--r--"),
        (UInt16(0o000), "---------"),
        (UInt16(0o777), "rwxrwxrwx"),
        (UInt16(0o4750), "rwxr-x---"),
    ])
    func permissions(mode: UInt16, expected: String) {
        #expect(PermissionsFormatter.symbolic(mode) == expected)
    }

    @Test("metadata is read for existing paths only")
    func metadata() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("opendisk-metadata-\(UUID().uuidString)")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)

        let metadata = try #require(FileMetadata.read(atPath: url.path))
        #expect(metadata.posixPermissions == 0o640)
        #expect(metadata.modificationDate != nil)
        #expect(metadata.creationDate != nil)
        #expect(metadata.date(for: .modified) == metadata.modificationDate)
        #expect(metadata.date(for: .permissions) == nil)
        #expect(metadata.ownerName == NSUserName())
        #expect(FileMetadata.read(atPath: url.path + "-missing") == nil)
    }

    @Test("scan durations pick sensible units", arguments: [
        (0.5, "ms"), (3.2, "seconds"), (65.0, "1 min, 5 sec"), (3_725.0, "1 hr, 2 min"),
    ])
    func durations(duration: Double, expectedFragment: String) {
        #expect(DurationFormatter.scanDuration(duration).contains(expectedFragment))
    }
}
