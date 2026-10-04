import SwiftUI

/// Shown once per off-device provider: states what is sent and shows the exact payload.
struct ConsentView: View {
    let provider: AIProvider
    let tools: AgentTools
    var onAgree: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var preview: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send scan data to \(provider.title)?").font(.headline)
            Text("""
            OpenDisk sends folder and file paths with their sizes, so the model can look around your scan. It never sends file contents. \
            \(AISettings.redactHome ? "Your home folder is shown as ~." : "Full paths are sent, including your user name. You can hide it in Settings › AI.") \
            Your provider's data policy applies to what is sent.
            """)
            .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Preview the first message") {
                ScrollView {
                    Text(preview ?? "Loading…")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 220)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Send", action: onAgree).keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 520)
        .task {
            let tools = tools
            preview = await Task.detached { tools.briefing() }.value
        }
    }
}
