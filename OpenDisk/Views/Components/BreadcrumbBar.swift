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
    var sizeOfPath: (String) -> Int64? = { _ in nil }
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
            row(components.map(Optional.some), showsSizes: true)
            row(components.map(Optional.some), showsSizes: false)
            ForEach(collapsedVariants(of: components), id: \.count) { variant in
                row(variant, showsSizes: false)
            }
            if let last = components.last {
                row([last], showsSizes: false)
            }
        }
    }

    private func collapsedVariants(of components: [PathComponent]) -> [[PathComponent?]] {
        guard components.count > 2 else { return [] }
        return (1..<(components.count - 1)).reversed().map { kept in
            [components[0], nil] + components.suffix(kept)
        }
    }

    private func row(_ components: [PathComponent?], showsSizes: Bool) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                if index > 0 {
                    Image(systemName: "chevron.forward")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 1)
                }
                if let component {
                    segment(component, showsSize: showsSizes)
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
    private func segment(_ component: PathComponent, showsSize: Bool) -> some View {
        if component.isLast {
            HStack(spacing: 5) {
                Text(component.name)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.callout)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onTapGesture { onNavigate(component.path) }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default) { onNavigate(component.path) }
        } else {
            let size = showsSize ? sizeOfPath(component.path).map(ByteFormatter.formatFileSize) : nil
            BreadcrumbLink(name: component.name, size: size) { onNavigate(component.path) }
        }
    }
}

private struct BreadcrumbSize: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .fixedSize()
    }
}

private struct BreadcrumbLink: View {
    let name: String
    var size: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Text(name)
                .foregroundStyle(hovering ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let size { BreadcrumbSize(text: size) }
        }
        .font(.callout)
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
