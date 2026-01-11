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
    let isLast: Bool

    init(name: String, path: String, isLast: Bool = false) {
        self.name = name
        self.path = path
        self.id = path
        self.isLast = isLast
    }
}

/// Full-width glass navigation bar with breadcrumb path
/// Implements Apple's Liquid Glass design system (macOS Tahoe)
struct BreadcrumbBar: View {
    let currentPath: String
    let rootPath: String
    let onNavigate: (String) -> Void
    let onBack: () -> Void
    let onComputerClick: () -> Void

    @State private var hoveredComponent: String?

    private var pathComponents: [PathComponent] {
        let components = currentPath.components(separatedBy: "/").filter { !$0.isEmpty }
        var result: [PathComponent] = []

        // Add Computer as root
        result.append(PathComponent(name: "Computer", path: rootPath, isLast: components.isEmpty && currentPath == rootPath))

        var buildPath = ""
        for (index, component) in components.enumerated() {
            if buildPath.isEmpty || buildPath == "/" {
                buildPath = "/" + component
            } else {
                buildPath = buildPath + "/" + component
            }
            let isLast = index == components.count - 1
            result.append(PathComponent(name: component, path: buildPath, isLast: isLast))
        }

        return result
    }

    private var canGoBack: Bool {
        currentPath != rootPath
    }

    var body: some View {
        HStack(spacing: 0) {
            // Back button
            Button {
                if canGoBack {
                    onBack()
                } else {
                    onComputerClick()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(canGoBack ? .primary : .tertiary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canGoBack && currentPath == rootPath)

            Divider()
                .frame(height: 20)
                .padding(.horizontal, 8)

            // Breadcrumb path
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(pathComponents) { component in
                        BreadcrumbSegment(
                            component: component,
                            isHovered: hoveredComponent == component.id,
                            onTap: {
                                if component.name == "Computer" && currentPath == rootPath {
                                    onComputerClick()
                                } else {
                                    onNavigate(component.path)
                                }
                            }
                        )
                        .onHover { isHovered in
                            hoveredComponent = isHovered ? component.id : nil
                        }

                        if !component.isLast {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.trailing, 16)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .glassEffect()
    }
}

/// Individual breadcrumb segment with hover effect
struct BreadcrumbSegment: View {
    let component: PathComponent
    let isHovered: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                if component.name == "Computer" {
                    Image(systemName: "desktopcomputer")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }

                Text(component.name)
                    .font(component.isLast ? .body.weight(.semibold) : .body)
                    .foregroundStyle(component.isLast ? .primary : .secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                if isHovered && !component.isLast {
                    Capsule()
                        .fill(.quaternary)
                }
            }
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}

#Preview {
    VStack(spacing: 20) {
        BreadcrumbBar(
            currentPath: "/",
            rootPath: "/",
            onNavigate: { _ in },
            onBack: { },
            onComputerClick: { }
        )

        BreadcrumbBar(
            currentPath: "/Users/test/Documents/Projects",
            rootPath: "/",
            onNavigate: { _ in },
            onBack: { },
            onComputerClick: { }
        )
    }
    .padding()
    .frame(width: 600)
}
