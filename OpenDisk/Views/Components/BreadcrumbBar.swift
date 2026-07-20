import SwiftUI

/// One segment of the breadcrumb path.
struct PathComponent: Identifiable {
    let name: String
    let path: String
    let isRoot: Bool
    let isLast: Bool

    var id: String { path }
}

/// DaisyDisk-style breadcrumb trail in the Liquid Glass functional layer:
/// chevron-separated glass segments from the scan root to the current folder,
/// with the current location shown prominently. This is the app's single
/// navigation-location indicator (the redundant window title is removed).
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
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 4) {
                HStack(spacing: 4) {
                    ForEach(pathComponents) { component in
                        segment(component)

                        if !component.isLast {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        // Keep the whole trail on one line; it scrolls horizontally if deep.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func segment(_ component: PathComponent) -> some View {
        let button = Button {
            if component.isRoot && component.isLast {
                onRootTap()
            } else {
                onNavigate(component.path)
            }
        } label: {
            HStack(spacing: 4) {
                if component.isRoot {
                    Image(systemName: "desktopcomputer")
                }
                Text(component.name).lineLimit(1)
            }
            .font(.callout)
        }

        // Current location is prominent (accent-filled glass, DaisyDisk-style);
        // ancestors are subtle glass chips.
        if component.isLast {
            button.buttonStyle(.glassProminent).tint(.accentColor)
        } else {
            button.buttonStyle(.glass)
        }
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
    .padding()
}
