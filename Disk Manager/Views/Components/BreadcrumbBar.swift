//
//  BreadcrumbBar.swift
//  Disk Manager
//
//  Created by 137137137 on 9/2/25.
//

import SwiftUI

struct PathComponent: Identifiable {
    let id: String
    let name: String
    let path: String

    init(name: String, path: String) {
        self.name = name
        self.path = path
        self.id = path
    }
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

        result.append(PathComponent(name: "Computer", path: rootPath))

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
        HStack(spacing: 4) {
            ForEach(pathComponents) { component in
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
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)

                if component.id != pathComponents.last?.id {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
