import AppKit
import SwiftUI
import SuperwarmKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Updates.self) private var updates
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Electricity") {
                Picker("Grid", selection: $model.settings.gridPreset) {
                    ForEach(GridPreset.allCases) { Text($0.label).tag($0) }
                }
                if model.settings.gridPreset == .custom {
                    LabeledContent("g CO₂e per kWh") {
                        TextField("g/kWh", value: $model.settings.customGramsPerKWh, format: .number)
                            .frame(width: 80)
                    }
                }
                LabeledContent("PUE \(model.settings.pue, format: .number.precision(.fractionLength(2)))") {
                    Slider(value: $model.settings.pue, in: 1.05...1.8, step: 0.01)
                }
                Text("Location-based. Providers rarely say which region serves you, so the US grid is the default. PUE is facility energy ÷ IT energy: hyperscalers report ~1.1, typical data centres ~1.5.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Comparisons") {
                LabeledContent("One-way commute (miles)") {
                    TextField("miles", value: $model.settings.commuteMilesOneWay, format: .number)
                        .frame(width: 80)
                }
            }

            Section("Menu bar") {
                Picker("Show", selection: $model.settings.menuBarPeriod) {
                    ForEach(AppSettings.MenuBarPeriod.allCases) { Text($0.label).tag($0) }
                }
            }

            Section("Updates") {
                LabeledContent("Version", value: updates.currentVersion)
                if updates.isEnabled {
                    Toggle("Check for updates automatically", isOn: Binding(
                        get: { updates.automaticallyChecks },
                        set: { updates.automaticallyChecks = $0 }
                    ))
                    Toggle("Download and install updates automatically", isOn: Binding(
                        get: { updates.automaticallyDownloads },
                        set: { updates.automaticallyDownloads = $0 }
                    ))
                    .help("Updates install the next time Superwarm quits.")
                    Button("Check Now") { updates.checkForUpdates() }
                } else {
                    Text("Updates are available in release builds installed from GitHub.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            RemoteMachinesSection()

            Section("Year in Carbon") {
                Text("A year-in-review slideshow appears in the menu from December 1 to January 15.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Preview now") { openWindow(id: "year-in-review") }
            }

            Section("Models") {
                Text("Correct the size tier or release month of models Superwarm doesn't know yet. Unknown models are dated by when they first appear in your logs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Edit model overrides…") { openOverrides() }
                    Button("Apply") { Task { await model.refresh() } }
                }
            }
        }
        .formStyle(.grouped)
        .tint(Theme.moss)
        .frame(width: 460)
        .padding(.vertical, 8)
    }

    private func openOverrides() {
        let url = AppPaths.modelOverrides
        if !FileManager.default.fileExists(atPath: url.path) {
            let template = """
            [
              { "prefix": "example-model-name", "tier": "large", "released": "2026-01" }
            ]

            """
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? template.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }
}

/// Remote machines whose usage is pulled in over SSH (`superwarm remote`).
struct RemoteMachinesSection: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var host = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        Section {
            let remotes = model.snapshot?.remotes ?? []
            ForEach(remotes) { remote in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: remote.lastError == nil ? "server.rack" : "exclamationmark.triangle")
                        .foregroundStyle(remote.lastError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.clay))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(remote.name)
                        Text(status(remote))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        run { try await model.removeRemote(remote.name) }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove \(remote.name) and the usage synced from it")
                }
            }
            HStack {
                TextField("Name", text: $name, prompt: Text("devbox"))
                    .frame(width: 110)
                TextField("SSH", text: $host, prompt: Text("me@devbox.example.com"))
                Button("Add") {
                    let (n, h) = (name.trimmingCharacters(in: .whitespaces), host.trimmingCharacters(in: .whitespaces))
                    run {
                        try await model.addRemote(name: n, ssh: h)
                        name = ""
                        host = ""
                    }
                }
                .disabled(name.isEmpty || host.isEmpty || busy)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(Theme.clay)
            }
            HStack {
                Text("Install the CLI there with the one-line installer. Superwarm connects with your SSH keys, without prompting, every 15 minutes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !remotes.isEmpty {
                    Button(busy ? "Syncing…" : "Sync Now") { run { await model.syncRemotes() } }
                        .disabled(busy)
                }
            }
        } header: {
            Text("Remote machines")
        }
    }

    private func status(_ remote: RemoteStatus) -> String {
        let via = remote.ssh.map { "ssh \($0)" } ?? "imported"
        let when = remote.lastSync.map { $0.formatted(.relative(presentation: .named)) } ?? "never"
        if let error = remote.lastError {
            return "\(via) · last attempt \(when) failed: \(error)"
        }
        return "\(via) · \(remote.responses) responses · synced \(when)"
    }

    private func run(_ action: @escaping () async throws -> Void) {
        busy = true
        error = nil
        Task {
            do { try await action() } catch { self.error = "\(error)" }
            busy = false
        }
    }
}
