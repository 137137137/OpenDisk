import SwiftUI

struct PathComponent: Identifiable {
    let name: String
    let path: String
    let isRoot: Bool
    let isLast: Bool

    var id: String { path }
}

struct BreadcrumbBar: View {
    let currentPath: String
    let rootPath: String
    let rootName: String
    let onNavigate: (String) -> Void

    private var pathComponents: [PathComponent] {
        var result = [PathComponent(
            name: rootName, path: rootPath, isRoot: true, isLast: currentPath == rootPath
        )]

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
        let components = pathComponents
        ViewThatFits(in: .horizontal) {
            row(components)
            ForEach(collapsedVariants(of: components), id: \.count) { variant in
                row(variant)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func collapsedVariants(of components: [PathComponent]) -> [[PathComponent?]] {
        guard components.count > 2 else { return [] }
        return (1..<(components.count - 1)).reversed().map { kept in
            [components[0], nil] + components.suffix(kept)
        }
    }

    private func row(_ components: [PathComponent]) -> some View {
        row(components.map(Optional.some))
    }

    private func row(_ components: [PathComponent?]) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 1)
                }
                if let component {
                    segment(component)
                        .layoutPriority(component.isLast ? 1 : 0)
                } else {
                    Text("…")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private func segment(_ component: PathComponent) -> some View {
        if component.isLast {
            Text(component.name)
                .font(.callout)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
        } else {
            BreadcrumbLink(name: component.name) { onNavigate(component.path) }
        }
    }
}

private struct BreadcrumbLink: View {
    let name: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Text(name)
            .font(.callout)
            .foregroundStyle(hovering ? .primary : .secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.quaternary.opacity(hovering ? 1 : 0))
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .onHover { hovering = $0 }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, action)
    }
}

#Preview {
    BreadcrumbBar(
        currentPath: "/Volumes/External/Documents/Projects",
        rootPath: "/Volumes/External",
        rootName: "External",
        onNavigate: { _ in }
    )
    .frame(width: 600)
    .padding()
}
