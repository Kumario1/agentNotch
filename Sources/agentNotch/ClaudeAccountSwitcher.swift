import CryptoKit
import Foundation

enum ClaudeAccountSwitchError: Error, Equatable {
    case noCredentials
    case unknownAccount
    case keychainFailed
}

enum ClaudeAccountSwitching {
    static let globalService = "Claude Code-credentials"
    static let backupPath = NSString(string: "~/.claude/.agentnotch-cred-backup.json").expandingTildeInPath
    static let defaultCredentialsPath = NSString(string: "~/.claude/.credentials.json").expandingTildeInPath

    static func namespacedService(for dir: URL) -> String {
        "\(globalService)-\(sha256Hex(dir.path).prefix(8))"
    }

    static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func accountID(for dir: URL) -> String { "claude:\(dir.path)" }

    static func dir(forAccountID id: String, among dirs: [URL]) -> URL? {
        dirs.first { accountID(for: $0) == id }
    }

    // Pure matching: which configured dir owns this live access token?
    static func matchingDir(accessToken: String, credentialsByPath: [String: Data]) -> String? {
        for (path, data) in credentialsByPath {
            guard let creds = ClaudeLimits.credentials(from: data),
                  creds.accessToken == accessToken else { continue }
            return path
        }
        return nil
    }
}

final class ClaudeAccountSwitcher {
    private let dirs: [URL]
    private let queue = DispatchQueue(label: "agentNotch.claude.switch", qos: .utility)

    init(dirs: [URL]) { self.dirs = dirs }

    func refreshActiveID(completion: @escaping (String?) -> Void) {
        queue.async {
            let id = self.activeAccountID()
            completion(id)
        }
    }

    func activate(accountID: String, completion: @escaping (Result<Void, ClaudeAccountSwitchError>) -> Void) {
        queue.async {
            let result = self.activateOnQueue(accountID: accountID)
            completion(result)
        }
    }

    private func activeAccountID() -> String? {
        guard let global = Self.keychainRead(service: ClaudeAccountSwitching.globalService),
              let live = ClaudeLimits.credentials(from: global) else { return nil }
        for dir in dirs {
            guard let data = Self.credentialsJSON(forDir: dir),
                  let creds = ClaudeLimits.credentials(from: data),
                  creds.accessToken == live.accessToken else { continue }
            return ClaudeAccountSwitching.accountID(for: dir)
        }
        return nil
    }

    private func activateOnQueue(accountID: String) -> Result<Void, ClaudeAccountSwitchError> {
        guard let dir = ClaudeAccountSwitching.dir(forAccountID: accountID, among: dirs) else {
            return .failure(.unknownAccount)
        }
        guard let source = Self.credentialsJSON(forDir: dir) else {
            return .failure(.noCredentials)
        }
        if let current = Self.keychainRead(service: ClaudeAccountSwitching.globalService) {
            Self.writeBackup(current)
        }
        guard Self.keychainWrite(service: ClaudeAccountSwitching.globalService, data: source) else {
            return .failure(.keychainFailed)
        }
        Self.mirrorCredentialsFile(source)
        return .success(())
    }

    // MARK: - Credential sources

    static func credentialsJSON(forDir dir: URL) -> Data? {
        let file = dir.appendingPathComponent(".credentials.json")
        if let data = FileManager.default.contents(atPath: file.path), !data.isEmpty {
            return data
        }
        if let data = keychainRead(service: ClaudeAccountSwitching.namespacedService(for: dir)), !data.isEmpty {
            return data
        }
        let defaultDir = URL(fileURLWithPath: NSString(string: "~/.claude").expandingTildeInPath, isDirectory: true)
        if dir.standardizedFileURL.path == defaultDir.standardizedFileURL.path,
           let data = keychainRead(service: ClaudeAccountSwitching.globalService), !data.isEmpty {
            return data
        }
        return nil
    }

    // MARK: - Keychain + file IO

    private static func keychainRead(service: String) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-w"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return data.isEmpty ? nil : data
    }

    @discardableResult
    private static func keychainWrite(service: String, data: Data) -> Bool {
        guard let json = String(data: data, encoding: .utf8) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = [
            "add-generic-password", "-U",
            "-a", NSUserName(),
            "-s", service,
            "-w", json,
        ]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private static func writeBackup(_ data: Data) {
        let url = URL(fileURLWithPath: ClaudeAccountSwitching.backupPath)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ClaudeAccountSwitching.backupPath)
    }

    private static func mirrorCredentialsFile(_ data: Data) {
        let path = ClaudeAccountSwitching.defaultCredentialsPath
        guard FileManager.default.fileExists(atPath: path) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}
