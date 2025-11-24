//
//  FolderRowView.swift
//  Disk Manager
//
//  Created by 137137137 on 9/2/25.
//

import SwiftUI

struct FolderRowView: View {
    let item: FolderItem
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                // Percentage badge - always show exact percentage
                Text(String(format: "%.1f%%", item.percentage))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 45, alignment: .trailing)

                Label {
                    HStack {
                        Text(item.name)
                            .lineLimit(1)

                        Spacer()

                        Text(item.formattedSize)
                            .monospacedDigit()

                        Text(item.formattedItemCount + " items")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: item.isDirectory ? "folder" : "doc")
                }

                if item.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

