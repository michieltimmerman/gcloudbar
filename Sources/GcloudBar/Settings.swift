// The Settings window. A plain window rather than SwiftUI's Settings scene: a
// menu-bar-only app has no app menu to open that from, and since macOS 14 it can't
// be opened programmatically.
//
// Toggles live in the state file like everything the app learns; the gcloud,
// Python, config-folder and browser overrides are defaults (`setting()`), which is
// what an app started by Finder or launch-at-login can read. Environment variables
// still win, for development and tests.
import AppKit
import SwiftUI

final class SettingsWindow: ObservableObject {
    static let shared = SettingsWindow()
    @Published var tab = "general"
    private var window: NSWindow?

    func show(tab: String? = nil) {
        if let tab { self.tab = tab }
        if window == nil {
            let w = NSWindow(contentViewController:
                NSHostingController(rootView: SettingsView(monitor: .shared, window: self)))
            w.title = "GcloudBar Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        debug("settings window: \(self.tab) tab, visible \(window?.isVisible ?? false)")
    }
}

struct SettingsView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var window: SettingsWindow

    var body: some View {
        TabView(selection: $window.tab) {
            GeneralSettings(monitor: monitor)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            GcloudSettings(monitor: monitor)
                .tabItem { Label("gcloud", systemImage: "terminal") }
                .tag("gcloud")
        }
        // A grouped Form scrolls and has no ideal height of its own; without a
        // fixed size the window shrinks to the tab bar.
        .frame(width: 560, height: 620)
        .padding(.top, 8)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var monitor: Monitor

    private let aheadChoices: [(minutes: Double, label: String)] =
        [(15, "15 minutes"), (30, "30 minutes"), (60, "1 hour"), (120, "2 hours"), (240, "4 hours")]

    var body: some View {
        Form {
            Section {
                Toggle("Renew automatically", isOn: effective(overrides.autoRenew, $monitor.state.autoLogin))
                    .disabled(overrides.autoRenew != nil)
                ArgumentNote(flag: "--auto-renew", active: overrides.autoRenew != nil)
                Picker("Renew ahead of expiry",
                       selection: effective(overrides.renewAheadMinutes, $monitor.state.renewAheadMinutes)) {
                    ForEach(aheadChoices, id: \.minutes) { Text($0.label).tag($0.minutes) }
                    if let m = overrides.renewAheadMinutes, !aheadChoices.contains(where: { $0.minutes == m }) {
                        Text(hms(m * 60)).tag(m)
                    }
                }
                .disabled(overrides.renewAheadMinutes != nil)
                ArgumentNote(flag: "--renew-ahead", active: overrides.renewAheadMinutes != nil)
                Picker("Session length until learned",
                       selection: effective(overrides.sessionHours, $monitor.state.sessionHours)) {
                    ForEach([8.0, 12, 16, 20, 24], id: \.self) { Text("\(Int($0)) hours").tag($0) }
                    if let h = overrides.sessionHours, ![8.0, 12, 16, 20, 24].contains(h) {
                        Text(hms(h * 3600)).tag(h)
                    }
                }
                .disabled(overrides.sessionHours != nil)
                ArgumentNote(flag: "--session-length", active: overrides.sessionHours != nil)
                LabeledContent("Learned") {
                    HStack {
                        Text(monitor.learnedLine).foregroundStyle(.secondary)
                        Button("Forget") { monitor.resetLearned() }
                    }
                }
            } header: {
                Text("Renewal")
            } footer: {
                Text("Renewal opens a browser login for you to approve, and only while you're at the "
                     + "Mac. Renewing well ahead keeps an agent working after you walk away.")
                    .foregroundStyle(.secondary)
            }

            Section("Login page") {
                Picker("Open login pages in", selection: browser) {
                    Text("Default browser").tag("")
                    ForEach(browsers, id: \.id) { Text($0.name).tag($0.id) }
                }
                .disabled(overrides.loginBrowser != nil || appEnv["GCLOUDBAR_LOGIN_BROWSER"] != nil)
                ArgumentNote(flag: "--login-browser", active: overrides.loginBrowser != nil)
            }

            Section {
                Toggle(monitor.adcTarget.map { "Also renew ADC (as \($0))" } ?? "Also renew ADC",
                       isOn: effective(overrides.renewADC, $monitor.state.renewADC))
                    .disabled(overrides.renewADC != nil)
                ArgumentNote(flag: "--renew-adc", active: overrides.renewADC != nil)
            } footer: {
                Text("Application Default Credentials have their own session: a second browser approval.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Notifications", isOn: effective(overrides.notifications, $monitor.state.notify))
                    .disabled(overrides.notifications != nil)
                ArgumentNote(flag: "--notifications", active: overrides.notifications != nil)
                Toggle("Launch at login", isOn: Binding(
                    get: { monitor.launchAtLogin },
                    set: { monitor.setLaunchAtLogin($0) }))
                if let note = monitor.launchAtLoginNote {
                    Text(note).foregroundStyle(.secondary)
                }
            } footer: {
                HStack {
                    Text("GcloudBar \(version)")
                    Spacer()
                    Link("github.com/michieltimmerman/gcloudbar",
                         destination: URL(string: "https://github.com/michieltimmerman/gcloudbar")!)
                }
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// Installed browsers, plus a configured one that isn't on the known list.
    private var browsers: [(id: String, name: String)] {
        var list = LoginBrowser.installed
        if let name = LoginBrowser.name, !list.contains(where: { $0.id == LoginBrowser.bundleID }) {
            list.append((LoginBrowser.bundleID, name))
        }
        return list
    }

    /// "" is the default browser (no $BROWSER hand-off).
    private var browser: Binding<String> {
        Binding(
            get: {
                monitor.state.opensLoginBrowser && LoginBrowser.appURL != nil ? LoginBrowser.bundleID : ""
            },
            set: { id in
                if !id.isEmpty { UserDefaults.standard.set(id, forKey: "GCLOUDBAR_LOGIN_BROWSER") }
                // Assigning state also redraws.
                monitor.state.useLoginBrowser = !id.isEmpty
            })
    }
}

/// A control showing a command-line override shows the overriding value (and is
/// disabled); otherwise it edits the saved setting.
private func effective<T>(_ override: T?, _ saved: Binding<T>) -> Binding<T> {
    Binding(get: { override ?? saved.wrappedValue }, set: { saved.wrappedValue = $0 })
}

private struct ArgumentNote: View {
    let flag: String
    let active: Bool

    var body: some View {
        if active {
            Text("Set by \(flag) for this run.").foregroundStyle(.secondary)
        }
    }
}

private struct GcloudSettings: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        Form {
            Section {
                if let c = monitor.compat {
                    LabeledContent("Installed gcloud", value: c.summary)
                    ForEach(Array(c.items.filter { !$0.ok }.enumerated()), id: \.offset) { _, item in
                        Label("\(item.serves): \(item.detail)",
                              systemImage: item.fatal ? "xmark.octagon" : "exclamationmark.triangle")
                            .foregroundStyle(item.fatal ? .red : .orange)
                    }
                } else {
                    Text(monitor.gcloudPath == nil
                         ? "gcloud not found"
                         : "Not checked: this gcloud isn't inside a Google Cloud SDK folder")
                        .foregroundStyle(.secondary)
                }
                Button("Check now") { monitor.checkCompat() }
            } header: {
                Text("Compatibility")
            } footer: {
                Text("Looks in your gcloud install for the internals GcloudBar relies on. "
                     + "Also checked at launch; the same check is GcloudBar --compat.")
                    .foregroundStyle(.secondary)
            }
            Section("Detected") {
                LabeledContent("gcloud", value: monitor.gcloudPath ?? "not found")
                LabeledContent("Python", value: monitor.pythonPath ?? "gcloud's default")
                LabeledContent("Account", value: monitor.state.account ?? "—")
                LabeledContent("Config folder", value: gcloudConfigDir.path)
            }
            Section {
                PathOverride(title: "gcloud", key: "GCLOUDBAR_GCLOUD") { monitor.locate() }
                PathOverride(title: "Python for gcloud", key: "CLOUDSDK_PYTHON") { monitor.locate() }
                PathOverride(title: "gcloud config folder", key: "CLOUDSDK_CONFIG", directory: true) {
                    monitor.configFolderChanged()
                }
            } header: {
                Text("Overrides")
            } footer: {
                Text("Leave these on Automatic unless detection picks the wrong one.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// One path setting: Automatic, or a file/folder picked with Choose….
private struct PathOverride: View {
    let title: String
    let key: String
    var directory = false
    let changed: () -> Void
    @AppStorage private var value: String

    init(title: String, key: String, directory: Bool = false, changed: @escaping () -> Void) {
        self.title = title
        self.key = key
        self.directory = directory
        self.changed = changed
        _value = AppStorage(wrappedValue: "", key)
    }

    var body: some View {
        LabeledContent(title) {
            HStack {
                Text(value.isEmpty ? "Automatic" : value)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(value.isEmpty ? .secondary : .primary)
                Button("Choose…") {
                    if let path = choose() {
                        value = path
                        changed()
                    }
                }
                if !value.isEmpty {
                    Button("Reset") {
                        value = ""
                        changed()
                    }
                }
            }
        }
        if overrides.value(forSettingKey: key) != nil, let flag = Overrides.flag(forSettingKey: key) {
            Text("Set by \(flag) for this run.").foregroundStyle(.secondary)
        } else if appEnv[key] != nil {
            Text("The \(key) environment variable overrides this.").foregroundStyle(.secondary)
        }
    }

    private func choose() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose \(title)"
        panel.canChooseFiles = !directory
        panel.canChooseDirectories = directory
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
