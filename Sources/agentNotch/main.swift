import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController!
    private var engine: UsageEngine!
    private var limits: LimitsEngine!

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = NotchController()
        engine = UsageEngine(store: controller.store)   // still feeds last-project footer
        engine.start()
        limits = LimitsEngine(config: AppConfig.load()) { [weak self] accounts in
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
app.setActivationPolicy(.accessory) // no Dock icon, no menu bar
let delegate = AppDelegate()
app.delegate = delegate
app.run()
