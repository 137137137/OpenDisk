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
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: item.isDirectory ? "folder" : "doc")
                }

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .opacity(item.isDirectory ? 1 : 0)
                    .padding(.trailing, 8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

