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
        HStack(spacing: 12) {
            // Icon and progress indicator
            HStack(spacing: 4) {
                Text(String(format: "%.1f%%", item.percentage))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)

                Image(systemName: item.isDirectory ? "folder" : "doc")
                    .font(.title3)
                    .foregroundStyle(item.isDirectory ? .accent : .secondary)
                    .frame(width: 20)
            }

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(item.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(item.formattedSize)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)

                        Text(item.formattedItemCount + " items")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(item.relativeModified)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .frame(minWidth: 60)

                    if item.isDirectory {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                // Progress bar for large items
                if item.percentage >= 1.0 {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(.quaternary)
                                .frame(height: 2)

                            RoundedRectangle(cornerRadius: 1)
                                .fill(.accent)
                                .frame(width: geometry.size.width * (item.percentage / 100), height: 2)
                        }
                    }
                    .frame(height: 2)
                    .padding(.top, 4)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
    }
}
