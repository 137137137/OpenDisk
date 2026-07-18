import SwiftUI

/// One segment of the breadcrumb path.
struct PathComponent: Identifiable {
    let name: String
    let path: String
    let isRoot: Bool
    let isLast: Bool

    var id: String { path }
}

/// Full-width glass navigation bar: back button, scrolling breadcrumb path,
/// refresh button.
struct BreadcrumbBar: View {
    let currentPath: String
    let rootPath: String
    /// Display name of the root segment (device name).
    let rootName: String
    let onNavigate: (String) -> Void
    let onBack: () -> Void
    /// Tapping the root segment while already at the root.
    let onRootTap: () -> Void
    let onRefresh: () -> Void

    @State private var hoveredComponent: String?

    /// Segments relative to the scanned root, so external volumes don't
    /// grow phantom "/Volumes" crumbs pointing outside the scan.
    private var pathComponents: [PathComponent] {
        var result = [PathComponent(
            name: rootName, path: rootPath, isRoot: true, isLast: currentPath == rootPath
        )]

        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard currentPath.hasPrefix(prefix) else { return result }

        let components = currentPath.dropFirst(prefix.count).split(separator: "/")
        var accumulatedPath = rootPath
        for (index, component) in components.enumerated() {
            accumulatedPath = accumulatedPath.hasSuffix("/")
                ? accumulatedPath + component
                : accumulatedPath + "/" + component
            result.append(PathComponent(
                name: String(component),
                path: accumulatedPath,
                isRoot: false,
                isLast: index == components.count - 1
            ))
        }
        return result
    }

    private var canGoBack: Bool {
        currentPath != rootPath
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(canGoBack ? .primary : .tertiary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canGoBack)

            Divider()
                .frame(height: 20)
                .padding(.horizontal, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(pathComponents) { component in
                        BreadcrumbSegment(
                            component: component,
                            isHovered: hoveredComponent == component.id,
                            onTap: {
                                if component.isRoot && currentPath == rootPath {
                                    onRootTap()
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

            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("r", modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .glassEffect()
    }
}

/// Individual breadcrumb segment with hover effect.
private struct BreadcrumbSegment: View {
    let component: PathComponent
    let isHovered: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                if component.isRoot {
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
            rootName: "Computer",
            onNavigate: { _ in },
            onBack: {},
            onRootTap: {},
            onRefresh: {}
        )

        BreadcrumbBar(
            currentPath: "/Volumes/External/Documents/Projects",
            rootPath: "/Volumes/External",
            rootName: "External",
            onNavigate: { _ in },
            onBack: {},
            onRootTap: {},
            onRefresh: {}
        )
    }
    .padding()
    .frame(width: 600)
}
