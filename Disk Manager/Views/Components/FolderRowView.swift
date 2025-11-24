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
                Label {
                    HStack {
                        Text(item.name)
                            .lineLimit(1)

                        Spacer()

                        Text(item.formattedSize)

                        Text(item.formattedItemCount + " items")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(item.relativeModified)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
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

