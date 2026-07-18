import SwiftUI

struct SettingsView: View {
    @State private var isFullDiskAccessGranted = false
    @State private var isCheckingAccess = false
    @AppStorage("fda_show_prompt_at_startup") private var showPromptAtStartup = true

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    HStack {
                        Circle()
                            .fill(isFullDiskAccessGranted ? .green : .orange)
                            .frame(width: 10, height: 10)

                        Text(isFullDiskAccessGranted ? "Granted" : "Not Granted")
                            .foregroundStyle(isFullDiskAccessGranted ? .green : .orange)

                        Spacer()

                        Button("Check Again") {
                            checkFullDiskAccessStatus()
                        }
                        .disabled(isCheckingAccess)
                    }
                }

                Text("Full Disk Access allows Disk Manager to analyze all files and folders on your system for accurate disk usage information.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !isFullDiskAccessGranted {
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

                if !isFullDiskAccessGranted {
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
        .onAppear(perform: checkFullDiskAccessStatus)
    }

    /// The probe does filesystem work; run it off the main thread.
    private func checkFullDiskAccessStatus() {
        isCheckingAccess = true
        Task {
            let granted = await Task.detached(priority: .userInitiated) {
                FullDiskAccess.isGranted
            }.value
            withAnimation(.easeInOut(duration: 0.3)) {
                isFullDiskAccessGranted = granted
                isCheckingAccess = false
            }
        }
    }
}

#Preview {
    SettingsView()
        .frame(width: 600, height: 500)
}
