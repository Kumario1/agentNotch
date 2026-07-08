import AppKit
import ServiceManagement
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
                onSave: { [weak self] updated in
                    self?.apply(updated)
                })
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 480, height: 520)
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
            (window?.contentView as? NSHostingView<SettingsView>)?.rootView = SettingsView(
                config: config,
                claudeHookInstalled: HookInstaller.claudeInstalled(),
                cursorHookInstalled: HookInstaller.cursorInstalled(),
                onSave: { [weak self] updated in self?.apply(updated) })
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func apply(_ updated: AppConfig) {
        config = updated
        config.save()
        HookInstaller.sync(config: config)
        setLaunchAtLogin(updated.launchAtLogin)
        onConfigSaved(updated)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        if enabled {
            try? service.register()
        } else {
            try? service.unregister()
        }
    }
}

struct SettingsView: View {
    @State var config: AppConfig
    let claudeHookInstalled: Bool
    let cursorHookInstalled: Bool
    let onSave: (AppConfig) -> Void

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
            }
            Section {
                HStack {
                    Spacer()
                    Button("Save") { onSave(config) }
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
