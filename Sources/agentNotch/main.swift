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
    private var engine: UsageEngine!
    private var limits: LimitsEngine!
    private var sessions: SessionEngine!
    private var settings: SettingsController!
    private var config = AppConfig.load()

    func applicationDidFinishLaunching(_ notification: Notification) {
        config = AppConfig.load()
        settings = SettingsController(config: config) { [weak self] updated in
            self?.config = updated
        }
        controller = NotchController(settings: settings, claudeDirs: config.claudeDirs)
        controller.start()
        HookInstaller.sync(config: config)

        engine = UsageEngine(store: controller.store)
        engine.start()
        sessions = SessionEngine(config: config, store: controller.store)
        sessions.start()
        limits = LimitsEngine(config: config) { [weak self] accounts in
            guard let self else { return }
            self.controller.store.accounts = accounts
            self.controller.setAccountCount(accounts.count)
        }
        limits.start()
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
