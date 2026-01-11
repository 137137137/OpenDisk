//
//  DeviceRow.swift
//  Disk Manager
//
//  Created by 137137137 on 9/2/25.
//

import SwiftUI

struct DeviceRow: View {
    let device: DeviceInfo
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .fontWeight(.medium)

                    if device.totalStorage > 0 {
                        Text("\(device.formattedUsedStorage) / \(device.formattedTotalStorage)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        StorageProgressBar(
                            totalStorage: device.totalStorage,
                            availableStorage: device.availableStorage
                        )
                    } else if let subtitle = device.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: device.icon)
                    .foregroundStyle(.tint)
            }
        }
        .buttonStyle(.plain)
    }
}
