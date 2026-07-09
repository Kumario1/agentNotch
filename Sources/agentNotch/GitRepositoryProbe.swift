import Foundation

enum GitRepositoryProbe {
    enum CommandResult {
        case success(String)
        case failure
    }

    typealias CommandRunner = (_ workingDirectory: String, _ arguments: [String]) -> CommandResult

    static func summary(for workingDirectory: String, run: CommandRunner? = nil) -> RepositorySummary? {
        let execute = run ?? systemRun
        guard let root = nonEmptyOutput(of: execute(workingDirectory, ["rev-parse", "--show-toplevel"])) else { return nil }

        let branch = nonEmptyOutput(of: execute(root, ["symbolic-ref", "--quiet", "--short", "HEAD"]))
            ?? nonEmptyOutput(of: execute(root, ["rev-parse", "--short", "HEAD"]))
        guard let branch,
              let numstat = successfulOutput(of: execute(root, ["diff", "--numstat", "HEAD"]))
        else { return nil }

        let rows = numstat.split(whereSeparator: \.isNewline).filter { !$0.isEmpty }
        let totals = rows.reduce(into: (files: 0, additions: 0, deletions: 0)) { total, row in
            let columns = row.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard columns.count == 3 else { return }
            total.files += 1
            total.additions += Int(columns[0]) ?? 0
            total.deletions += Int(columns[1]) ?? 0
        }

        return RepositorySummary(root: root, branch: branch, changedFiles: totals.files,
                                 additions: totals.additions, deletions: totals.deletions)
    }

    private static func successfulOutput(of result: CommandResult) -> String? {
        guard case let .success(value) = result else { return nil }
        return value
    }

    private static func nonEmptyOutput(of result: CommandResult) -> String? {
        let trimmed = successfulOutput(of: result)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func systemRun(workingDirectory: String, arguments: [String]) -> CommandResult {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return .failure }
            return .success(String(decoding: data, as: UTF8.self))
        } catch {
            return .failure
        }
    }
}
