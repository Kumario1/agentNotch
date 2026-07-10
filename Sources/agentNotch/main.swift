import AppKit
import Darwin

private func terminateOtherInstances() {
    let current = getpid()
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-x", "agentNotch"]
    let pipe = Pipe()
    p.standardOutput = pipe
    guard (try? p.run()) != nil else { return }
    p.waitUntilExit()

    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let pids = out.split(whereSeparator: \.isNewline).compactMap { pid_t($0) }
    for pid in pids where pid != current { kill(pid, SIGTERM) }
    usleep(200_000)
    for pid in pids where pid != current && kill(pid, 0) == 0 {
        kill(pid, SIGKILL)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController!
    private var limits: LimitsEngine!
    private var sessions: SessionEngine!
    private var settings: SettingsController!
    private var config = AppConfig.load()

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings = SettingsController(config: config) { [weak self] updated in
            self?.config = updated
        }
        controller = NotchController(settings: settings,
                                     claudeDirs: config.claudeDirs,
                                     placement: WidgetPlacement.load())
        controller.start()
        HookInstaller.sync(config: config)
        // Re-register after reinstall/move; ad-hoc rebuilds invalidate prior BTM entries.
        LaunchAtLogin.sync(enabled: config.launchAtLogin)

        sessions = SessionEngine(config: config, store: controller.store)
        controller.store.loadOrganize()
        sessions.updatePinned(controller.store.pinnedSessionIDs)
        controller.store.onPinsChanged = { [weak self] in
            guard let self else { return }
            self.sessions.updatePinned(self.controller.store.pinnedSessionIDs)
        }
        sessions.start()
        limits = LimitsEngine(config: config) { [weak self] accounts in
            self?.controller.store.accounts = accounts
        }
        limits.start()
        controller.onExpand = { [weak self] in self?.limits.refreshNow() }
        controller.show()

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func screensChanged() { controller.reposition() }
}

let app = NSApplication.shared
terminateOtherInstances()
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
