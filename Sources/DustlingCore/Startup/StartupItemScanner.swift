import Foundation

/// Lists launch agents and daemons and toggles user-level agents with `launchctl`.
///
/// Login items (Background Task Management) are deliberately not listed: see
/// `docs/superpowers/research/login-items-spike.md`. System-level items are listed but can only be
/// changed with admin rights, which arrive with the privileged helper in a later plan.
public struct StartupItemScanner: Sendable {
    private static let launchctl = "/bin/launchctl"

    private let environment: SystemEnvironment
    private let commands: any CommandRunning
    private let apps: [InstalledApp]

    public init(environment: SystemEnvironment, commands: any CommandRunning, apps: [InstalledApp]) {
        self.environment = environment
        self.commands = commands
        self.apps = apps
    }

    public func scan() -> [StartupItem] { scanWithIssues().items }

    public func scanWithIssues() -> (items: [StartupItem], issues: [ScanIssue]) {
        var issues: [ScanIssue] = []
        let userDisabled = disabledLabels(domain: "gui/\(environment.userID)", issues: &issues)
        let systemDisabled = disabledLabels(domain: "system", issues: &issues)

        let sources: [(URL, StartupScope, Set<String>?)] = [
            (environment.userLibrary.appending(path: "LaunchAgents"), .userAgent, userDisabled),
            // System agents load in the user's GUI domain, so the per-user override database applies.
            (environment.systemLibrary.appending(path: "LaunchAgents"), .systemAgent, userDisabled),
            (environment.systemLibrary.appending(path: "LaunchDaemons"), .systemDaemon, systemDisabled),
        ]
        var items: [StartupItem] = []
        for (dir, scope, disabled) in sources {
            let plists: [URL]
            switch list(dir) {
            case .success(let urls): plists = urls
            case .failure(let failure):
                if let issue = failure.issue { issues.append(issue) }
                continue
            }
            for url in plists {
                let (item, parsed) = makeItem(url, scope: scope, disabled: disabled)
                items.append(item)
                if !parsed { issues.append(.unreadable(url)) }
            }
        }
        items.sort { ($0.scope.rawValue, $0.label) < ($1.scope.rawValue, $1.label) }
        return (items, issues)
    }

    /// `.skipped(reason: "disabled" | "enabled")` means the change succeeded.
    public func setEnabled(_ item: StartupItem, _ enabled: Bool) -> DeletionOutcome {
        switch item.scope {
        case .systemAgent, .systemDaemon:
            return .needsAdmin
        case .loginItem:
            return .failed(reason: "login items can only be changed in System Settings > General > Login Items")
        case .userAgent:
            return enabled ? enable(item) : disable(item)
        }
    }

    // MARK: - Toggle

    private func disable(_ item: StartupItem) -> DeletionOutcome {
        let target = "gui/\(environment.userID)/\(item.label)"
        if let failure = run("disable", [target]) { return failure }
        let notLoaded = ["No such process", "Could not find specified service"]
        if let failure = run("bootout", [target], tolerating: { _, stderr in
            notLoaded.contains { stderr.contains($0) }
        }) { return failure }
        return .skipped(reason: "disabled")
    }

    private func enable(_ item: StartupItem) -> DeletionOutcome {
        guard let plist = item.plistURL else {
            return .failed(reason: "launchctl enable failed: no property list for \(item.label)")
        }
        let uid = environment.userID
        if let failure = run("enable", ["gui/\(uid)/\(item.label)"]) { return failure }
        if let failure = run("bootstrap", ["gui/\(uid)", plist.path(percentEncoded: false)], tolerating: { status, stderr in
            status == 5 || stderr.localizedCaseInsensitiveContains("already")
        }) { return failure }
        return .skipped(reason: "enabled")
    }

    /// Returns nil on success (or a tolerated failure), otherwise the failed outcome.
    private func run(
        _ verb: String, _ arguments: [String], tolerating: (Int32, String) -> Bool = { _, _ in false }
    ) -> DeletionOutcome? {
        do {
            let result = try commands.run(Self.launchctl, [verb] + arguments)
            if result.status == 0 { return nil }
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if tolerating(result.status, stderr) { return nil }
            return .failed(reason: "launchctl \(verb) failed: \(stderr)")
        } catch {
            return .failed(reason: "launchctl \(verb) failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Disabled state

    /// nil when the state could not be read (an issue is recorded); never silently "all enabled".
    private func disabledLabels(domain: String, issues: inout [ScanIssue]) -> Set<String>? {
        let command = "launchctl print-disabled \(domain)"
        do {
            let result = try commands.run(Self.launchctl, ["print-disabled", domain])
            guard result.status == 0 else {
                let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                issues.append(.commandFailed(command: command, reason: stderr))
                return nil
            }
            return Self.parseDisabled(result.stdout)
        } catch {
            issues.append(.commandFailed(command: command, reason: error.localizedDescription))
            return nil
        }
    }

    /// Lines look like `"com.foo" => disabled` (or `=> true` on older macOS).
    static func parseDisabled(_ output: String) -> Set<String> {
        var disabled: Set<String> = []
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("\""), let closing = line.dropFirst().firstIndex(of: "\"") else { continue }
            let label = String(line[line.index(after: line.startIndex)..<closing])
            guard let arrow = line.range(of: "=>") else { continue }
            let value = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces).lowercased()
            if value == "disabled" || value == "true" { disabled.insert(label) }
        }
        return disabled
    }

    // MARK: - Listing

    /// `.failure(nil)` means a missing directory (silent).
    private func list(_ dir: URL) -> Result<[URL], ListFailure> {
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            return .success(urls.filter { $0.pathExtension == "plist" })
        } catch {
            let ns = error as NSError
            let posix = (ns.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap {
                $0.domain == NSPOSIXErrorDomain ? Int32($0.code) : nil
            }
            if ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError || posix == ENOENT {
                return .failure(ListFailure(issue: nil))
            }
            if ns.code == NSFileReadNoPermissionError || posix == EPERM || posix == EACCES {
                return .failure(ListFailure(issue: .missingFullDiskAccess(dir)))
            }
            return .failure(ListFailure(issue: .unreadable(dir)))
        }
    }

    private struct ListFailure: Error {
        let issue: ScanIssue?
    }

    private func makeItem(_ url: URL, scope: StartupScope, disabled: Set<String>?) -> (StartupItem, parsed: Bool) {
        let fileName = url.lastPathComponent
        var label = fileName
        var program: String?
        var plistDisabled = false
        var parsed = false
        if let data = try? Data(contentsOf: url),
           let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] {
            parsed = true
            label = (dict["Label"] as? String) ?? url.deletingPathExtension().lastPathComponent
            program = (dict["Program"] as? String)
                ?? (dict["ProgramArguments"] as? [String])?.first
            plistDisabled = (dict["Disabled"] as? Bool) ?? false
        }
        let enabled = !plistDisabled && !(disabled?.contains(label) ?? false)
        let item = StartupItem(
            label: label, scope: scope, plistURL: url, program: program,
            ownerAppName: program.flatMap(ownerName(forProgram:)),
            isEnabled: enabled, managedInSystemSettingsOnly: false)
        return (item, parsed)
    }

    private func ownerName(forProgram program: String) -> String? {
        let parts = URL(filePath: program).standardizedFileURL.pathComponents
        for app in apps {
            let appParts = app.url.standardizedFileURL.pathComponents
            if parts.count > appParts.count, Array(parts.prefix(appParts.count)) == appParts {
                return app.displayName
            }
        }
        return nil
    }
}
