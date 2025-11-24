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
        HStack {
            // Back button
            Button {
                onBack()
            } label: {
                Label("Back", systemImage: "chevron.left")
                    .labelStyle(.iconOnly)
            }
            .disabled(currentPath == rootPath)

            // Up button
            Button {
                let parentPath = URL(fileURLWithPath: currentPath).deletingLastPathComponent().path
                if parentPath != currentPath {
                    onNavigate(parentPath)
                }
            } label: {
                Label("Up", systemImage: "arrow.up")
                    .labelStyle(.iconOnly)
            }
            .disabled(currentPath == rootPath || currentPath == "/")

            Divider()

            // Breadcrumb path
            HStack {
                ForEach(Array(pathComponents.enumerated()), id: \.offset) { index, component in
                    Button {
                        if component.name == "Computer" && currentPath != rootPath {
                            onNavigate(component.path)
                        } else if component.name == "Computer" && currentPath == rootPath {
                            onComputerClick()
                        } else {
                            onNavigate(component.path)
                        }
                    } label: {
                        Text(component.name)
                            .foregroundStyle(index == pathComponents.count - 1 ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)

                    if index < pathComponents.count - 1 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()
        }
    }
}
