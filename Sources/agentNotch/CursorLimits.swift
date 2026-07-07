import Foundation

// Cursor has no local quota file; report presence + last transcript activity.
final class CursorAccountProvider {
    private let dir: URL
    private let onUpdate: (AccountUsage) -> Void
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var last: AccountUsage?

    init(dir: URL, onUpdate: @escaping (AccountUsage) -> Void) {
        self.dir = dir
        self.onUpdate = onUpdate
        self.queue = DispatchQueue(label: "agentNotch.cursor.\(dir.lastPathComponent)", qos: .utility)
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 15)
        t.setEventHandler { [weak self] in self?.poll() }
        timer = t
        t.resume()
    }

    private func poll() {
        var acc = AccountUsage(id: "cursor:\(dir.path)", product: .cursor, label: "Cursor")
        let projects = dir.appendingPathComponent("projects", isDirectory: true)
        guard FileManager.default.fileExists(atPath: projects.path) else {
            acc.status = "not found"
            publish(acc)
            return
        }
        var newest: Date?
        if let en = FileManager.default.enumerator(
            at: projects, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for case let f as URL in en where f.pathExtension == "jsonl" {
                let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let m, newest == nil || m > newest! { newest = m }
            }
        }
        if let newest {
            acc.lastActivity = newest
            acc.status = "connected"
        } else {
            acc.status = "no sessions yet"
        }
        publish(acc)
    }

    private func publish(_ acc: AccountUsage) {
        if acc != last { last = acc; onUpdate(acc) }
    }
}
