import SwiftUI

private let kSetupWizardDoneSuffix = ".TMSetupWizardCompleted"

enum SetupWizardState {
    private static var doneKey: String {
        (Bundle.main.bundleIdentifier ?? "TunnelMonitor") + kSetupWizardDoneSuffix
    }

    static var hasCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: doneKey) }
        set { UserDefaults.standard.set(newValue, forKey: doneKey) }
    }
}

struct SetupWizardView: View {
    @Environment(\.dismiss) private var dismiss
    var onSaved: () -> Void

    @State private var values: [String: String] = [:]
    @State private var errorMessage: String?
    @State private var isSaving = false

    private let catalog = WizardFieldLoader.load()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Configuration")
                    .font(.title2.weight(.semibold))
                Text("Enter the values normally placed in /opt/tunnel-monitor/config.env. Administrator approval is required to save.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .tmGlassCard(tint: .accentColor)
            .padding(.bottom, 12)

            ScrollView {
                TMSectionContainer {
                    ForEach(catalog.sections) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title)
                                .font(.headline)
                            ForEach(section.fields) { field in
                                fieldRow(field)
                            }
                        }
                        .tmGlassCard()
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 420)

            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.top, 6)
            }

            HStack {
                Button("Configure later") {
                    SetupWizardState.hasCompleted = true
                    dismiss()
                }
                .tmGlassActionButton()
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save to /opt/tunnel-monitor/config.env") {
                    save()
                }
                .tmGlassProminentButton()
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
            }
            .padding(.top, 12)
        }
        .padding(20)
        .frame(width: 520)
        .tmAppWindowBackground()
        .onAppear {
            if values.isEmpty {
                seedDefaults()
            }
        }
    }

    @ViewBuilder
    private func fieldRow(_ field: WizardFieldSpec) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(field.label)
                .font(.subheadline.weight(.medium))
            Group {
                if field.secure {
                    SecureField("", text: binding(for: field.key))
                } else {
                    TextField("", text: binding(for: field.key))
                }
            }
            .textFieldStyle(.roundedBorder)
            if let help = field.help, !help.isEmpty {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: { values[key, default: ""] },
            set: { values[key] = $0 }
        )
    }

    private func seedDefaults() {
        var next: [String: String] = [:]
        for section in catalog.sections {
            for f in section.fields {
                next[f.key] = f.defaultValue ?? ""
            }
        }
        values = next
    }

    @MainActor
    private func save() {
        errorMessage = nil
        isSaving = true
        defer { isSaving = false }

        var pairs: [(key: String, value: String)] = []
        for section in catalog.sections {
            for f in section.fields {
                let trimmed = values[f.key, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
                let v = trimmed.isEmpty ? (f.defaultValue ?? "") : trimmed
                if v.contains("REPLACE_WITH") {
                    errorMessage = "Replace every REPLACE_WITH_* placeholder (\(f.label))"
                    return
                }
                if f.secure && v.isEmpty {
                    errorMessage = "Missing required value: \(f.label)"
                    return
                }
                if ["SMTP_SERVER", "SMTP_USER", "ALERT_FROM", "ALERT_TO", "REMOTE_LAN_IP", "REMOTE_WAN_IP", "REMOTE_DDNS"].contains(f.key) && v.isEmpty {
                    errorMessage = "Missing required value: \(f.label)"
                    return
                }
                pairs.append((key: f.key, value: v))
            }
        }

        let body = ConfigEnvWriter.renderLines(pairs)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnel-monitor-config-\(UUID().uuidString).env")
        do {
            try body.data(using: .utf8)?.write(to: tmp)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        } catch {
            errorMessage = "Could not write temp file: \(error.localizedDescription)"
            return
        }

        let srcEsc = tmp.path.replacingOccurrences(of: "'", with: "'\\''")
        let cmd = "/usr/bin/install -m 0600 -o root -g wheel '\(srcEsc)' '\(MonitorPaths.config)'"
        let (code, out) = Actions.runAsRoot(cmd)
        try? FileManager.default.removeItem(at: tmp)

        if code != 0 {
            errorMessage = "Save failed (\(code)): \(out)"
            return
        }

        SetupWizardState.hasCompleted = true
        onSaved()
        dismiss()
    }
}
