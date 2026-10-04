import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension FocusedValues {
    @Entry var analyzer: DiskAnalyzer?
}

struct ExportCommands: Commands {
    @FocusedValue(\.analyzer) private var analyzer

    var body: some Commands {
        CommandGroup(replacing: .importExport) {
            Button("Export Scan for LLM (Markdown)…") { export(.markdown) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(analyzer?.completedScan == nil)
            Button("Export Scan as JSON…") { export(.json) }
                .disabled(analyzer?.completedScan == nil)
        }
    }

    enum Format { case markdown, json }

    @MainActor
    private func export(_ format: Format) {
        guard let analyzer else { return }
        Task { @MainActor in
            guard var digest = await analyzer.currentDigest() else { return }
            if AISettings.redactHome { digest = digest.redacted() }

            let panel = NSSavePanel()
            let base = (digest.rootPath as NSString).lastPathComponent
            let stamp = digest.date.formatted(.iso8601.year().month().day())
            switch format {
            case .markdown:
                panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
                panel.nameFieldStringValue = "OpenDisk \(base) \(stamp).md"
            case .json:
                panel.allowedContentTypes = [.json]
                panel.nameFieldStringValue = "OpenDisk \(base) \(stamp).json"
            }
            panel.message = AISettings.redactHome
                ? "Your home folder is shown as ~. Only paths and sizes are exported."
                : "Only paths and sizes are exported."
            guard panel.runModal() == .OK, let url = panel.url else { return }

            do {
                let data: Data = switch format {
                case .markdown: Data((AgentPrompt.exportPreamble + "\n" + digest.markdown()).utf8)
                case .json: try digest.jsonData()
                }
                try data.write(to: url, options: .atomic)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }
}
