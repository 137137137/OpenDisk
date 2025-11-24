//
//  Disk_ManagerTests.swift
//  Disk ManagerTests
//
//  Created by 137137137 on 9/2/25.
//

import Testing
@testable import Disk_Manager

struct Disk_ManagerTests {
    @Test func testByteFormatterFormatFileSize() {
        // Test basic byte formatting
        #expect(ByteFormatter.formatFileSize(1024) == "1 KB")
        #expect(ByteFormatter.formatFileSize(1024 * 1024) == "1 MB")
        #expect(ByteFormatter.formatFileSize(1024 * 1024 * 1024) == "1 GB")
    }

    @Test func testPathFilterShouldSkipPath() {
        // Test virtual filesystem skipping
        #expect(PathFilter.shouldSkipPath("/dev"))
        #expect(PathFilter.shouldSkipPath("/proc/something"))
        #expect(PathFilter.shouldSkipPath("/System/Volumes/Data/.Trashes"))
        #expect(!PathFilter.shouldSkipPath("/Users/test"))
    }

    @Test func testFolderItemComparable() {
        let item1 = FolderItem(name: "a.txt", path: "/a.txt", size: 100, isDirectory: false, itemCount: 1, lastModified: Date())
        let item2 = FolderItem(name: "b.txt", path: "/b.txt", size: 200, isDirectory: false, itemCount: 1, lastModified: Date())
        let item3 = FolderItem(name: "folder", path: "/folder", size: 300, isDirectory: true, itemCount: 5, lastModified: Date())

        // Directories should come before files
        #expect(item3 < item1)
        #expect(item3 < item2)

        // Files should be sorted by size (descending)
        #expect(item2 < item1)
    }
}
