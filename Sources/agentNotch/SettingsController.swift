import AppKit
import SwiftUI

final class SettingsController {
    private var window: NSWindow?
    private var config: AppConfig
    private let onConfigSaved: (AppConfig) -> Void

    init(config: AppConfig, onConfigSaved: @escaping (AppConfig) -> Void) {
        self.config = config
        self.onConfigSaved = onConfigSaved
    }

    func show() {
        if window == nil {
            let view = SettingsView(
                config: config,
                claudeHookInstalled: HookInstaller.claudeInstalled(),
                cursorHookInstalled: HookInstaller.cursorInstalled(),
                launchStatus: LaunchAtLogin.currentStatus,
                launchError: nil,
                onSave: { [weak self] updated in
                    self?.apply(updated) ?? .init(
                        status: .notRegistered,
                        errorMessage: "Settings closed",
                        installHint: nil)
                })
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 480, height: 560)
            let w = NSWindow(
                contentRect: host.frame,
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false)
            w.title = "agentNotch Settings"
            w.contentView = host
            w.center()
            w.isReleasedWhenClosed = false
            // Drop the Dock icon again when Settings closes (show() adds it below).
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                NSApp.setActivationPolicy(.accessory)
            }
            window = w
        } else {
            refreshRootView(launchStatus: LaunchAtLogin.currentStatus, launchError: nil)
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @discardableResult
    private func apply(_ updated: AppConfig) -> LaunchAtLogin.Result {
        config = updated
        config.save()
        HookInstaller.sync(config: config)
        let result = LaunchAtLogin.setEnabled(updated.launchAtLogin)
        onConfigSaved(updated)
        refreshRootView(launchStatus: result.status, launchError: result.errorMessage)
        return result
    }

    private func refreshRootView(launchStatus: LaunchAtLogin.Status, launchError: String?) {
        (window?.contentView as? NSHostingView<SettingsView>)?.rootView = SettingsView(
            config: config,
            claudeHookInstalled: HookInstaller.claudeInstalled(),
            cursorHookInstalled: HookInstaller.cursorInstalled(),
            launchStatus: launchStatus,
            launchError: launchError,
            onSave: { [weak self] updated in
                self?.apply(updated) ?? .init(
                    status: .notRegistered,
                    errorMessage: "Settings closed",
                    installHint: nil)
            })
    }
}

struct SettingsView: View {
    @State var config: AppConfig
    let claudeHookInstalled: Bool
    let cursorHookInstalled: Bool
    let launchStatus: LaunchAtLogin.Status
    let launchError: String?
    let onSave: (AppConfig) -> LaunchAtLogin.Result

    @State private var liveLaunchStatus: LaunchAtLogin.Status
    @State private var liveLaunchError: String?

    init(
        config: AppConfig,
        claudeHookInstalled: Bool,
        cursorHookInstalled: Bool,
        launchStatus: LaunchAtLogin.Status,
        launchError: String?,
        onSave: @escaping (AppConfig) -> LaunchAtLogin.Result
    ) {
        self.config = config
        self.claudeHookInstalled = claudeHookInstalled
        self.cursorHookInstalled = cursorHookInstalled
        self.launchStatus = launchStatus
        self.launchError = launchError
        self.onSave = onSave
        _liveLaunchStatus = State(initialValue: launchStatus)
        _liveLaunchError = State(initialValue: launchError)
    }

    var body: some View {
        Form {
            Section("Watched directories") {
                Text("Changes apply on next launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                dirList("Claude", paths: config.claudeDirs.map(\.path)) { config.claudeDirs = urls($0) }
                dirList("Codex", paths: config.codexDirs.map(\.path)) { config.codexDirs = urls($0) }
                dirList("Cursor", paths: config.cursorDirs.map(\.path)) { config.cursorDirs = urls($0) }
            }
            Section("Approvals") {
                Toggle("Claude Code (PermissionRequest hook)", isOn: $config.approvalsEnabledClaude)
                Text(claudeHookInstalled ? "Hook installed" : "Hook not installed")
                    .font(.caption)
                    .foregroundStyle(claudeHookInstalled ? .green : .secondary)
                Toggle("Cursor (best-effort; deny reliable)", isOn: $config.approvalsEnabledCursor)
                Text(cursorHookInstalled ? "Hook installed" : "Hook not installed")
                    .font(.caption)
                    .foregroundStyle(cursorHookInstalled ? .green : .secondary)
            }
            Section("General") {
                Toggle("Launch at login", isOn: $config.launchAtLogin)
                Text(liveLaunchStatus.label)
                    .font(.caption)
                    .foregroundStyle(statusColor(liveLaunchStatus))
                if let liveLaunchError {
                    Text(liveLaunchError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if let installHint = LaunchAtLogin.installHint() {
                    Text(installHint)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if liveLaunchStatus == .requiresApproval {
                    Button("Open Login Items…") {
                        LaunchAtLogin.openSystemSettings()
                    }
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button("Save") {
                        let result = onSave(config)
                        liveLaunchStatus = result.status
                        liveLaunchError = result.errorMessage
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            Section("About") {
                Text("agentNotch — local notch companion for coding agents.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: launchStatus) { _, new in liveLaunchStatus = new }
        .onChange(of: launchError) { _, new in liveLaunchError = new }
    }

    private func statusColor(_ status: LaunchAtLogin.Status) -> Color {
        switch status {
        case .enabled: return .green
        case .requiresApproval: return .orange
        case .notRegistered: return .secondary
        case .notFound, .unavailable: return .red
        }
    }

    @ViewBuilder
    private func dirList(_ title: String, paths: [String], onChange: @escaping ([String]) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            ForEach(paths, id: \.self) { path in
                HStack {
                    Text(path).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                    Spacer()
                    Button(role: .destructive) {
                        var next = paths
                        next.removeAll { $0 == path }
                        onChange(next)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button("Add…") {
                pickDirectory { if let p = $0 { onChange(paths + [p]) } }
            }
        }
    }

    private func urls(_ paths: [String]) -> [URL] {
        paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private func pickDirectory(completion: @escaping (String?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.begin { resp in
            completion(resp == .OK ? panel.url?.path : nil)
        }
    }
}
