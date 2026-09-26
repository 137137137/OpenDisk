import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let collectedFile = UTType(exportedAs: "ideals.OpenDisk.collected-file", conformingTo: .data)
}

extension NSPasteboard.PasteboardType {
    static let collectedFile = NSPasteboard.PasteboardType(UTType.collectedFile.identifier)
}

final class FileDragItem: NSObject, NSPasteboardWriting {
    let file: CollectedFile
    let exportsFileURL: Bool

    init(_ file: CollectedFile, exportsFileURL: Bool = true) {
        self.file = file
        self.exportsFileURL = exportsFileURL
    }

    private var fileURL: NSURL? {
        exportsFileURL && !file.path.hasPrefix("::") ? file.url as NSURL : nil
    }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        (fileURL?.writableTypes(for: pasteboard) ?? []) + [.collectedFile]
    }

    func writingOptions(
        forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard
    ) -> NSPasteboard.WritingOptions {
        guard type != .collectedFile, let fileURL else { return [] }
        return fileURL.writingOptions(forType: type, pasteboard: pasteboard)
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == .collectedFile { return try? JSONEncoder().encode(file) }
        return fileURL?.pasteboardPropertyList(forType: type)
    }
}

@MainActor
final class FileDragSource: NSObject, NSDraggingSource {
    static let shared = FileDragSource()

    private static let maxPreviewImages = 12
    private var onEnd: ((NSDragOperation) -> Void)?

    @discardableResult
    func begin(
        _ files: [CollectedFile],
        exportsFileURLs: Bool = true,
        onEnd: @escaping (NSDragOperation) -> Void
    ) -> Bool {
        guard !files.isEmpty,
              let event = NSApp.currentEvent,
              event.type == .leftMouseDragged || event.type == .leftMouseDown,
              let view = event.window?.contentView
        else { return false }

        let cursor = view.convert(event.locationInWindow, from: nil)
        let items = files.enumerated().map { index, file in
            let item = NSDraggingItem(
                pasteboardWriter: FileDragItem(file, exportsFileURL: exportsFileURLs)
            )
            let image = index < Self.maxPreviewImages ? Self.previewImage(for: file) : nil
            let size = image?.size ?? NSSize(width: 32, height: 32)
            let offset = CGFloat(min(index, Self.maxPreviewImages)) * 3
            let origin = NSPoint(
                x: cursor.x - 14 + offset,
                y: cursor.y - size.height / 2 + (view.isFlipped ? offset : -offset)
            )
            item.setDraggingFrame(NSRect(origin: origin, size: size), contents: image)
            return item
        }

        finish()
        self.onEnd = onEnd
        let session = view.beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = exportsFileURLs
        return true
    }

    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        Self.operationMask(for: context)
    }

    nonisolated static func operationMask(for context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.copy, .generic] : .copy
    }

    func draggingSession(
        _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        finish(operation)
    }

    private func finish(_ operation: NSDragOperation = []) {
        let pending = onEnd
        onEnd = nil
        pending?(operation)
    }

    private static func previewImage(for file: CollectedFile) -> NSImage? {
        let renderer = ImageRenderer(content: FileDragLabel(file: file))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage
    }
}

private struct FileDragLabel: View {
    let file: CollectedFile

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: file.path.hasPrefix("::") ? FileIcon.folder : FileIcon.icon(for: file.path))
                .resizable()
                .frame(width: 16, height: 16)
            Text(file.name).lineLimit(1)
            Text(file.formattedSize)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.body)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: 320, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            Color(nsColor: .windowBackgroundColor).opacity(0.92),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
    }
}

private struct FileDragModifier: ViewModifier {
    let files: (CGPoint) -> [CollectedFile]
    let exportsFileURLs: Bool
    let onBegin: ([CollectedFile]) -> Void
    let onEnd: (NSDragOperation) -> Void

    @State private var isDragging = false

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    guard !isDragging else { return }
                    isDragging = true
                    let payload = files(value.startLocation)
                    guard !payload.isEmpty else { return }
                    onBegin(payload)
                    let dragging = $isDragging
                    let started = FileDragSource.shared.begin(
                        payload, exportsFileURLs: exportsFileURLs
                    ) { operation in
                        dragging.wrappedValue = false
                        onEnd(operation)
                    }
                    if !started { onEnd([]) }
                }
                .onEnded { _ in isDragging = false }
        )
    }
}

extension View {
    func fileDrag(
        _ files: @escaping (CGPoint) -> [CollectedFile],
        exportsFileURLs: Bool = true,
        onBegin: @escaping ([CollectedFile]) -> Void = { _ in },
        onEnd: @escaping (NSDragOperation) -> Void = { _ in }
    ) -> some View {
        modifier(FileDragModifier(
            files: files, exportsFileURLs: exportsFileURLs, onBegin: onBegin, onEnd: onEnd
        ))
    }
}
