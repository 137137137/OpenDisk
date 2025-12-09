import SwiftUI
import AppKit

struct SettingsView: View {
    @State private var fdaStatus: Bool = false
    @State private var isCheckingFDA: Bool = false
    @AppStorage("fda_show_prompt_at_startup") private var showPromptAtStartup: Bool = true

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    HStack {
                        Circle()
                            .fill(fdaStatus ? .green : .orange)
                            .frame(width: 10, height: 10)

                        Text(fdaStatus ? "Granted" : "Not Granted")
                            .foregroundStyle(fdaStatus ? .green : .orange)

                        Spacer()

                        Button("Check Again") {
                            checkFDAStatus()
                        }
                        .disabled(isCheckingFDA)
                    }
                }

                Text("Full Disk Access allows Disk Manager to analyze all files and folders on your system for accurate disk usage information.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !fdaStatus {
                    Button {
                        FullDiskAccess.openSystemSettings()
                    } label: {
                        Label("Open Privacy & Security Settings", systemImage: "arrow.up.forward.square")
                    }

                    Text("After granting access, click 'Check Again' to verify.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("Full Disk Access", systemImage: "lock.shield")
            }

            Section {
                Toggle(isOn: $showPromptAtStartup) {
                    VStack(alignment: .leading) {
                        Text("Check Full Disk Access at startup")

                        Text("Shows a prompt if Full Disk Access is not granted")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !FullDiskAccess.isGranted {
                    Button("Reset Prompt Suppression") {
                        FullDiskAccess.resetPromptSuppression()
                    }
                }
            } header: {
                Label("Startup Behavior", systemImage: "power")
            }

            Section {
                Text("""
                Why does Disk Manager need Full Disk Access?

                • Analyze system files and protected folders
                • Calculate accurate disk usage across all directories
                • Access application containers and caches
                • Provide complete disk analysis results
                """)
                .font(.callout)
            } header: {
                Label("About Permissions", systemImage: "info.circle")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear {
            checkFDAStatus()
        }
    }

    private func checkFDAStatus() {
        isCheckingFDA = true
        DispatchQueue.global(qos: .userInitiated).async {
            let status = FullDiskAccess.isGranted
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.3)) {
                    self.fdaStatus = status
                    self.isCheckingFDA = false
                }
            }
        }
    }
}

#Preview {
    SettingsView()
        .frame(width: 600, height: 500)
}
