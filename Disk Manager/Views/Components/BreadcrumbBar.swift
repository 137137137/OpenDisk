//
//  BreadcrumbBar.swift
//  Disk Manager
//
//  Created by 137137137 on 9/2/25.
//

import SwiftUI

struct PathComponent {
    let name: String
    let path: String
}

struct BreadcrumbBar: View {
    let currentPath: String
    let rootPath: String
    let onNavigate: (String) -> Void
    let onBack: () -> Void
    let onComputerClick: () -> Void

    private var pathComponents: [PathComponent] {
        let components = currentPath.components(separatedBy: "/").filter { !$0.isEmpty }
        var result: [PathComponent] = []

        // Add root
        result.append(PathComponent(name: "Computer", path: rootPath))

        // Build path components
        var buildPath = ""
        for component in components {
            if buildPath.isEmpty || buildPath == "/" {
                buildPath = "/" + component
            } else {
                buildPath = buildPath + "/" + component
            }
            result.append(PathComponent(name: component, path: buildPath))
        }

        return result
    }

    var body: some View {
        HStack(spacing: 8) {
            // Back button
            Button {
                onBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.plain)
            .disabled(currentPath == rootPath)

            // Up button
            Button {
                let parentPath = URL(fileURLWithPath: currentPath).deletingLastPathComponent().path
                if parentPath != currentPath {
                    onNavigate(parentPath)
                }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.plain)
            .disabled(currentPath == rootPath || currentPath == "/")

            Divider()
                .frame(height: 16)

            // Breadcrumb path
            HStack(spacing: 4) {
                ForEach(Array(pathComponents.enumerated()), id: \.offset) { index, component in
                    Button {
                        // Special case: "Computer" should navigate to root path only if we're not already there
                        if component.name == "Computer" && currentPath != rootPath {
                            print("DEBUG: Computer breadcrumb clicked - navigating to root: \(component.path)")
                            onNavigate(component.path)
                        } else if component.name == "Computer" && currentPath == rootPath {
                            // If we're already at root, then go back to device selection
                            onComputerClick()
                        } else {
                            print("DEBUG: Breadcrumb clicked - navigating to: \(component.path)")
                            onNavigate(component.path)
                        }
                    } label: {
                        Text(component.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(index == pathComponents.count - 1 ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)

                    if index < pathComponents.count - 1 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
