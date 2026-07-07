import Foundation

// Owns one provider per configured account dir; merges their updates into a
// single sorted list and hands it to the main thread.
final class LimitsEngine {
    private var claudeProviders: [ClaudeAccountProvider] = []
    private var codexProviders: [CodexAccountProvider] = []
    private var accounts: [String: AccountUsage] = [:]
    private let mergeQueue = DispatchQueue(label: "agentNotch.limits")
    private let onPublish: ([AccountUsage]) -> Void

    init(config: AppConfig, onPublish: @escaping ([AccountUsage]) -> Void) {
        self.onPublish = onPublish
        let update: (AccountUsage) -> Void = { [weak self] acc in
            self?.mergeQueue.async { self?.merge(acc) }
        }
        claudeProviders = config.claudeDirs.map { ClaudeAccountProvider(dir: $0, onUpdate: update) }
        codexProviders = config.codexDirs.map { CodexAccountProvider(dir: $0, onUpdate: update) }
    }

    func start() {
        claudeProviders.forEach { $0.start() }
        codexProviders.forEach { $0.start() }
    }

    private func merge(_ acc: AccountUsage) {
        accounts[acc.id] = acc
        let sorted = accounts.values.sorted {
            ($0.product.rawValue, $0.label, $0.id) < ($1.product.rawValue, $1.label, $1.id)
        }
        DispatchQueue.main.async { self.onPublish(sorted) }
    }
}
