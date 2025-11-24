import SwiftUI
import AppKit

struct SettingsView: View {
    @State private var fdaStatus: Bool = false
    @State private var isCheckingFDA: Bool = false
    @AppStorage("fda_show_prompt_at_startup") private var showPromptAtStartup: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "gearshape")
                    .font(.title2)
                    .foregroundStyle(.primary)

                Text("Settings")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()
            }
            .padding(20)

            Divider()

            // Settings content
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Full Disk Access Section
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "lock.shield")
                                .font(.title3)
                                .foregroundStyle(.blue)

                            Text("Full Disk Access")
                                .font(.headline)
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            // Status indicator
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(fdaStatus ? .green : .orange)
                                    .frame(width: 10, height: 10)

                                Text(fdaStatus ? "Granted" : "Not Granted")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(fdaStatus ? .green : .orange)

                                Spacer()

                                Button("Check Status") {
                                    checkFDAStatus()
                                }
                                .buttonStyle(.bordered)
                                .disabled(isCheckingFDA)
                            }
                            .padding()

                            // Explanation
                            Text("Full Disk Access allows Disk Manager to analyze all files and folders on your system for accurate disk usage information.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            // Grant access button
                            if !fdaStatus {
                                VStack(alignment: .leading, spacing: 12) {
                                    Button {
                                        FullDiskAccess.openSystemSettings()
                                    } label: {
                                        HStack {
                                            Image(systemName: "arrow.up.forward.square")
                                            Text("Open Privacy & Security Settings")
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.large)

                                    Text("After granting access, click 'Check Status' to verify.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding()

                    // Startup behavior
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "power")
                                .font(.title3)
                                .foregroundStyle(.blue)

                            Text("Startup Behavior")
                                .font(.headline)
                        }

                        Toggle(isOn: $showPromptAtStartup) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Check Full Disk Access at startup")
                                    .font(.system(size: 14))

                                Text("Shows a prompt if Full Disk Access is not granted")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding()

                        if !FullDiskAccess.isGranted {
                            Button("Reset Prompt Suppression") {
                                FullDiskAccess.resetPromptSuppression()
                            }
                            .buttonStyle(.bordered)
                            .font(.caption)
                        }
                    }
                    .padding()

                    // About section
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "info.circle")
                                .font(.title3)
                                .foregroundStyle(.blue)

                            Text("About Permissions")
                                .font(.headline)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Why does Disk Manager need Full Disk Access?")
                                .font(.system(size: 14, weight: .semibold))

                            Text("""
                            • Analyze system files and protected folders
                            • Calculate accurate disk usage across all directories
                            • Access application containers and caches
                            • Provide complete disk analysis results
                            """)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding()
                    }
                    .padding()
                }
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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