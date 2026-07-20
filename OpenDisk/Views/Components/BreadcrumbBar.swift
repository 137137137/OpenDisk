import SwiftUI

/// One segment of the breadcrumb path.
struct PathComponent: Identifiable {
    let name: String
    let path: String
    let isRoot: Bool
    let isLast: Bool

    var id: String { path }
}

/// Finder-style path bar in the content layer: clickable segments from the
/// scan root to the current folder. Navigation *controls* (back, refresh)
/// live in the window toolbar, not here, and the bar carries no custom
/// background — per the platform guidance, glass and bar effects belong to
/// the system's navigation layer.
struct BreadcrumbBar: View {
    let currentPath: String
    let rootPath: String
    /// Display name of the root segment (device name).
    let rootName: String
    let onNavigate: (String) -> Void
    /// Tapping the root segment while already at the root.
    let onRootTap: () -> Void

    /// Segments relative to the scanned root, so external volumes don't
    /// grow phantom "/Volumes" crumbs pointing outside the scan.
    private var pathComponents: [PathComponent] {
        var result = [PathComponent(
            name: rootName, path: rootPath, isRoot: true, isLast: currentPath == rootPath
        )]

        // Synthetic locations ("::Name") aren't under the scan root; show
        // them as a single crumb after the root.
        if currentPath.hasPrefix("::") {
            result.append(PathComponent(
                name: String(currentPath.dropFirst(2)),
                path: currentPath, isRoot: false, isLast: true
            ))
            return result
        }

        let prefix = rootPath.directoryPrefix
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

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(pathComponents) { component in
                        BreadcrumbSegment(
                            component: component,
                            onTap: {
                                if component.isRoot && component.isLast {
                                    onRootTap()
                                } else {
                                    onNavigate(component.path)
                                }
                            }
                        )

                        if !component.isLast {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }

            Divider()
        }
    }
}

/// Individual breadcrumb segment with hover effect (owned locally, so
/// hovering never invalidates the whole bar).
private struct BreadcrumbSegment: View {
    let component: PathComponent
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
                    .font(component.isLast ? .callout.weight(.semibold) : .callout)
                    .foregroundStyle(component.isLast ? .primary : .secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .hoverHighlight(cornerRadius: 6, isEnabled: !component.isLast)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    BreadcrumbBar(
        currentPath: "/Volumes/External/Documents/Projects",
        rootPath: "/Volumes/External",
        rootName: "External",
        onNavigate: { _ in },
        onRootTap: {}
    )
    .frame(width: 600)
}
