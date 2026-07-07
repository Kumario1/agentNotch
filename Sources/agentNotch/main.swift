import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController!
    private var engine: UsageEngine!

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = NotchController()
        engine = UsageEngine(store: controller.store)
        engine.start()
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
