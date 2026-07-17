import Foundation
import Darwin

public struct ComputerListEntry: Codable, Sendable, Equatable {
    public let name: String
    public let path: String
    public let kind: String
    public let byteSize: Int?

    public init(name: String, path: String, kind: String, byteSize: Int?) {
        self.name = name
        self.path = path
        self.kind = kind
        self.byteSize = byteSize
    }
}

public struct ComputerReadResult: Codable, Sendable, Equatable {
    public let path: String
    public let content: String
    public let truncated: Bool

    public init(path: String, content: String, truncated: Bool) {
        self.path = path
        self.content = content
        self.truncated = truncated
    }
}

public struct ComputerCommandResult: Codable, Sendable, Equatable {
    public let exitCode: Int32
    public let output: String
    public let truncated: Bool
    public let timedOut: Bool
    public let cancelled: Bool

    public init(
        exitCode: Int32,
        output: String,
        truncated: Bool,
        timedOut: Bool = false,
        cancelled: Bool = false
    ) {
        self.exitCode = exitCode
        self.output = output
        self.truncated = truncated
        self.timedOut = timedOut
        self.cancelled = cancelled
    }
}

private final class CommandOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var didTruncate = false

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        if data.count < limit {
            let available = limit - data.count
            data.append(chunk.prefix(available))
            if chunk.count > available { didTruncate = true }
        } else if !chunk.isEmpty {
            didTruncate = true
        }
    }

    func snapshot() -> (Data, Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (data, didTruncate)
    }
}

private final class CommandProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancellationRequested = false

    func register(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldCancel = cancellationRequested
        lock.unlock()
        if shouldCancel { terminate(process) }
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let process = self.process
        lock.unlock()
        if let process { terminate(process) }
    }

    func terminateForTimeout() {
        lock.lock()
        let process = self.process
        lock.unlock()
        if let process { terminate(process) }
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellationRequested
    }

    private func terminate(_ process: Process) {
        guard process.isRunning else { return }
        let rootPID = process.processIdentifier
        let descendants = descendantPIDs(of: rootPID)
        for pid in descendants.reversed() { Darwin.kill(pid, SIGTERM) }
        Darwin.kill(rootPID, SIGTERM)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1) {
            let remaining = self.descendantPIDs(of: rootPID)
            // Keep the original identities: once the root exits, resistant
            // descendants are reparented and can no longer be rediscovered by
            // walking from that root.
            let killSet = Set(descendants).union(remaining)
            for pid in killSet.reversed() where pid > 0 { Darwin.kill(pid, SIGKILL) }
            if process.isRunning { Darwin.kill(rootPID, SIGKILL) }
        }
    }

    private func descendantPIDs(of rootPID: pid_t) -> [pid_t] {
        var descendants: [pid_t] = []
        var queue = [rootPID]
        var visited: Set<pid_t> = [rootPID]

        while !queue.isEmpty {
            let parent = queue.removeFirst()
            let requiredBytes = Darwin.proc_listchildpids(parent, nil, 0)
            guard requiredBytes > 0 else { continue }
            var children = [pid_t](
                repeating: 0,
                count: Int(requiredBytes) / MemoryLayout<pid_t>.stride
            )
            let writtenBytes = children.withUnsafeMutableBytes { buffer in
                Darwin.proc_listchildpids(parent, buffer.baseAddress, Int32(buffer.count))
            }
            guard writtenBytes > 0 else { continue }
            let count = min(children.count, Int(writtenBytes) / MemoryLayout<pid_t>.stride)
            for child in children.prefix(count) where child > 0 && visited.insert(child).inserted {
                descendants.append(child)
                queue.append(child)
            }
        }
        return descendants
    }
}

private struct CommandSandbox: Sendable {
    let directory: URL
    let scriptURL: URL
    let profileURL: URL
}

/// Filesystem and shell primitives used only behind ToolRegistry's schemas,
/// current-owner-request binding, sandbox, and audit trail.
struct SafeComputerAccess {
    let homeURL: URL
    let allowedRoots: [URL]
    let maximumListEntries: Int
    let maximumReadCharacters: Int
    let maximumCommandOutputBytes: Int
    let maximumCommandDurationSeconds: TimeInterval

    private let fileManager: FileManager

    init(
        allowedRoots: [URL],
        maximumListEntries: Int,
        maximumReadCharacters: Int,
        maximumCommandOutputBytes: Int,
        maximumCommandDurationSeconds: TimeInterval,
        fileManager: FileManager = .default
    ) {
        self.homeURL = fileManager.homeDirectoryForCurrentUser.standardizedFileURL
        self.allowedRoots = allowedRoots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        self.maximumListEntries = min(max(maximumListEntries, 1), 250)
        self.maximumReadCharacters = min(max(maximumReadCharacters, 1_000), 40_000)
        self.maximumCommandOutputBytes = min(max(maximumCommandOutputBytes, 4_096), 64_000)
        self.maximumCommandDurationSeconds = min(max(maximumCommandDurationSeconds, 1), 120)
        self.fileManager = fileManager
    }

    func list(path: String?) throws -> [ComputerListEntry] {
        if path == nil {
            var seen = Set<String>()
            return allowedRoots.compactMap { root in
                guard fileManager.fileExists(atPath: root.path),
                      !isSensitive(root),
                      seen.insert(root.path).inserted else { return nil }
                return ComputerListEntry(
                    name: root.lastPathComponent,
                    path: root.path,
                    kind: "directory",
                    byteSize: nil
                )
            }
        }
        let url = try resolve(path ?? homeURL.path, mustExist: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ToolRegistryError.notFound
        }
        guard isDirectory.boolValue else { throw ToolRegistryError.wrongItemType }

        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        let children = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: []
        )

        return Array(children
            .filter { !isSensitive($0.resolvingSymlinksInPath()) }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(maximumListEntries))
            .map { child in
                let values = try? child.resourceValues(forKeys: keys)
                let kind: String
                if values?.isDirectory == true { kind = "directory" }
                else if values?.isRegularFile == true { kind = "file" }
                else { kind = "other" }
                return ComputerListEntry(
                    name: child.lastPathComponent,
                    path: child.path,
                    kind: kind,
                    byteSize: values?.fileSize
                )
            }
    }

    func read(path: String, requestedCharacters: Int?) throws -> ComputerReadResult {
        let url = try resolve(path, mustExist: true)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw ToolRegistryError.wrongItemType }

        let characterLimit = min(max(requestedCharacters ?? maximumReadCharacters, 500), maximumReadCharacters)
        let byteLimit = characterLimit * 4
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: byteLimit + 1) ?? Data()

        let byteTruncated = data.count > byteLimit
        let source = byteTruncated ? data.prefix(byteLimit) : data[...]
        guard !source.contains(0),
              let decoded = String(data: Data(source), encoding: .utf8) else {
            throw ToolRegistryError.binaryFile
        }
        let scalars = decoded.unicodeScalars
        let controlCount = scalars.reduce(into: 0) { count, scalar in
            let value = scalar.value
            if (value < 0x20 && value != 0x09 && value != 0x0A && value != 0x0D) || value == 0x7F {
                count += 1
            }
        }
        guard controlCount <= 2,
              scalars.isEmpty || (controlCount * 100) <= scalars.count * 2 else {
            throw ToolRegistryError.binaryFile
        }
        let characterTruncated = decoded.count > characterLimit
        let content = characterTruncated ? String(decoded.prefix(characterLimit)) : decoded

        return ComputerReadResult(
            path: url.path,
            content: content,
            truncated: byteTruncated || characterTruncated
        )
    }

    func openURL(for target: String) throws -> URL {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: trimmed),
           let scheme = components.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            guard components.host?.isEmpty == false,
                  components.user == nil,
                  components.password == nil else {
                throw ToolRegistryError.sensitivePath
            }
            let sensitiveQueryNames: Set<String> = [
                "token", "key", "api_key", "apikey", "access_token", "auth", "password"
            ]
            guard !(components.queryItems ?? []).contains(where: {
                sensitiveQueryNames.contains($0.name.lowercased())
            }), let url = components.url else {
                throw ToolRegistryError.sensitivePath
            }
            return url
        }

        if !trimmed.contains("/"), !trimmed.hasPrefix("~"),
           let application = installedApplication(named: trimmed) {
            return application
        }
        let url = try resolve(trimmed, mustExist: true)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        let executionCapableExtensions: Set<String> = [
            "app", "command", "workflow", "action", "scpt", "applescript",
            "sh", "zsh", "bash", "fish", "py", "rb", "pl", "js", "jar",
            "tool", "pkg", "mpkg", "dmg", "bundle", "plugin", "prefpane",
            "qlgenerator", "saver", "mdimporter", "appex", "exe", "desktop",
            "mobileconfig", "webloc", "url", "inetloc", "alias", "shortcut"
        ]
        guard !executionCapableExtensions.contains(url.pathExtension.lowercased()) else {
            throw ToolRegistryError.commandRejected
        }
        if values.isDirectory == true { return url }
        guard values.isRegularFile == true else { throw ToolRegistryError.wrongItemType }
        guard !fileManager.isExecutableFile(atPath: url.path) else {
            throw ToolRegistryError.commandRejected
        }
        return url
    }

    func workingDirectory(for path: String?) throws -> URL {
        let defaultDirectory = allowedRoots.first(where: { root in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
                && !isSensitive(root)
        })
        guard path != nil || defaultDirectory != nil else { throw ToolRegistryError.accessDenied }
        let url = try resolve(path ?? defaultDirectory!.path, mustExist: true)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { throw ToolRegistryError.wrongItemType }
        return url
    }

    func validateCommand(_ command: String) throws {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4_000, !trimmed.contains("\0") else {
            throw ToolRegistryError.invalidArgument("command")
        }
        guard !referencesSensitiveLocation(command) else { throw ToolRegistryError.commandRejected }
    }

    func run(command: String, in workingDirectory: URL) async throws -> ComputerCommandResult {
        try Task.checkCancellation()
        let outputLimit = maximumCommandOutputBytes
        let durationLimit = maximumCommandDurationSeconds
        let sandbox = try makeCommandSandbox(command: command)
        defer { try? fileManager.removeItem(at: sandbox.directory) }
        var environment = sanitizedEnvironment()
        environment["TMPDIR"] = sandbox.directory.path
        let processEnvironment = environment
        let invocation = [
            "/usr/bin/sandbox-exec",
            "-f", shellQuote(sandbox.profileURL.path),
            "/bin/zsh", shellQuote(sandbox.scriptURL.path)
        ].joined(separator: " ")
        let processControl = CommandProcessControl()

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()
                let completion = DispatchSemaphore(value: 0)
                let collector = CommandOutputCollector(limit: outputLimit)
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                // The required login shell sees only this fixed wrapper. The
                // approved command lives in a 0600 script executed inside a
                // macOS sandbox scoped to the configured roots.
                process.arguments = ["-lc", invocation]
                process.currentDirectoryURL = workingDirectory
                process.environment = processEnvironment
                process.standardOutput = pipe
                process.standardError = pipe
                process.terminationHandler = { _ in completion.signal() }
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        handle.readabilityHandler = nil
                    } else {
                        collector.append(chunk)
                    }
                }

                do {
                    try process.run()
                    processControl.register(process)
                    pipe.fileHandleForWriting.closeFile()

                    var timedOut = false
                    if completion.wait(timeout: .now() + durationLimit) == .timedOut {
                        timedOut = true
                        processControl.terminateForTimeout()
                        if completion.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                            Darwin.kill(process.processIdentifier, SIGKILL)
                            _ = completion.wait(timeout: .now() + 1)
                        }
                    }

                    // Allow the final readability callback to drain bytes that
                    // were already in the pipe, then close without waiting on a
                    // descendant that inherited stdout.
                    usleep(20_000)
                    pipe.fileHandleForReading.readabilityHandler = nil
                    pipe.fileHandleForReading.closeFile()
                    let (kept, truncated) = collector.snapshot()

                    let cancelled = processControl.isCancelled
                    continuation.resume(returning: ComputerCommandResult(
                        exitCode: cancelled ? 130 : (timedOut ? 124 : process.terminationStatus),
                        output: String(decoding: kept, as: UTF8.self),
                        truncated: truncated,
                        timedOut: timedOut,
                        cancelled: cancelled
                    ))
                } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    pipe.fileHandleForWriting.closeFile()
                    pipe.fileHandleForReading.closeFile()
                    if process.isRunning { process.terminate() }
                    continuation.resume(throwing: error)
                }
            }
            }
        }, onCancel: {
            processControl.cancel()
        })
    }

    func resolve(_ input: String, mustExist: Bool) throws -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0") else {
            throw ToolRegistryError.invalidArgument("path")
        }

        let expanded: String
        if trimmed == "~" { expanded = homeURL.path }
        else if trimmed.hasPrefix("~/") {
            expanded = homeURL.appendingPathComponent(String(trimmed.dropFirst(2))).path
        } else { expanded = trimmed }

        let candidate: URL
        if expanded.hasPrefix("/") { candidate = URL(fileURLWithPath: expanded) }
        else { candidate = homeURL.appendingPathComponent(expanded) }

        let standardized = candidate.standardizedFileURL
        let exists = fileManager.fileExists(atPath: standardized.path)
        if mustExist && !exists { throw ToolRegistryError.notFound }

        let canonical: URL
        if exists {
            canonical = standardized.resolvingSymlinksInPath()
        } else {
            canonical = standardized.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent(standardized.lastPathComponent)
        }

        guard allowedRoots.contains(where: { root in
            canonical.path == root.path || canonical.path.hasPrefix(root.path + "/")
        }) else { throw ToolRegistryError.accessDenied }
        guard !isSensitive(canonical) else { throw ToolRegistryError.sensitivePath }
        return canonical
    }

    private func isSensitive(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents.map { $0.lowercased() }
        let forbiddenComponents: Set<String> = [
            ".ssh", ".gnupg", ".aws", ".azure", ".kube", ".config", ".claude",
            ".gem", ".password-store", ".1password", ".docker", "keychains",
            "credentials", "secrets", ".secrets", "keyrings"
        ]
        if components.contains(where: { forbiddenComponents.contains($0) }) { return true }

        let joinedPath = "/" + components.joined(separator: "/") + "/"
        let forbiddenSubpaths = [
            "/.config/gh/", "/.config/gcloud/", "/.config/op/", "/.config/stripe/",
            "/.config/vercel/", "/.local/share/keyrings/", "/library/keychains/"
        ]
        if forbiddenSubpaths.contains(where: joinedPath.contains) { return true }

        let name = url.lastPathComponent.lowercased()
        let forbiddenNames: Set<String> = [
            ".netrc", ".npmrc", ".pypirc", ".git-credentials", "openclaw.json",
            "auth.json", "credentials.json", "secrets.json", "id_rsa", "id_ed25519"
        ]
        if forbiddenNames.contains(name) || name == ".env" || name.hasPrefix(".env.") { return true }

        let forbiddenExtensions: Set<String> = ["pem", "key", "p12", "pfx", "keystore"]
        return forbiddenExtensions.contains(url.pathExtension.lowercased())
    }

    private func referencesSensitiveLocation(_ command: String) -> Bool {
        let lowercase = command.lowercased()
        let forbiddenFragments = [
            "/.ssh", "~/.ssh", "$home/.ssh", "/.gnupg", "~/.gnupg", "/.aws",
            "~/.aws", "/keychains", ".env", ".netrc", ".npmrc", ".pypirc",
            ".git-credentials", "openclaw.json", "id_rsa", "id_ed25519",
            "credentials.json", "secrets.json", "security find-generic-password",
            "security find-internet-password", "security dump-keychain"
        ]
        return forbiddenFragments.contains(where: lowercase.contains)
    }

    private func installedApplication(named requestedName: String) -> URL? {
        let requested = requestedName.lowercased().hasSuffix(".app")
            ? String(requestedName.dropLast(4))
            : requestedName
        let normalized = requested.lowercased()
        let applicationRoots = allowedRoots.filter {
            $0.lastPathComponent.lowercased() == "applications"
        }
        for root in applicationRoots {
            for directory in [root, root.appendingPathComponent("Utilities", isDirectory: true)] {
                guard let children = try? fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: []
                ) else { continue }
                for match in children {
                    guard match.pathExtension.lowercased() == "app",
                          match.deletingPathExtension().lastPathComponent.lowercased() == normalized,
                          !isSensitive(match) else { continue }
                    let resolved = match.resolvingSymlinksInPath()
                    let trustedCryptexRoot = URL(
                        fileURLWithPath: "/System/Volumes/Preboot/Cryptexes/App/System/Applications",
                        isDirectory: true
                    )
                    let permittedRoots = applicationRoots + [trustedCryptexRoot]
                    let remainsInApplicationRoot = permittedRoots.contains { root in
                        resolved.path == root.path || resolved.path.hasPrefix(root.path + "/")
                    }
                    guard remainsInApplicationRoot, !isSensitive(resolved) else { continue }
                    var isDirectory: ObjCBool = false
                    guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
                          isDirectory.boolValue else { continue }
                    return resolved
                }
            }
        }
        return nil
    }

    private func makeCommandSandbox(command: String) throws -> CommandSandbox {
        guard fileManager.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else {
            throw ToolRegistryError.commandRejected
        }

        let temporaryRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .resolvingSymlinksInPath()
        let directory = temporaryRoot
            .appendingPathComponent("AuroraCommand-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let scriptURL = directory.appendingPathComponent("approved-command.zsh")
        try Data((command + "\n").utf8).write(to: scriptURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: scriptURL.path)

        let sensitiveURLs = try discoveredSensitiveURLs()
        let writeRootFilters = allowedRoots.flatMap { sandboxAliasedPaths(for: $0) }
            .map { "  (subpath \(sandboxString($0)))" }
            .joined(separator: "\n")
        let sensitiveReadRules = sensitiveURLs.map {
            "(deny file-read* (\($0.hasDirectoryPath ? "subpath" : "literal") \(sandboxString($0.path))))"
        }.joined(separator: "\n")
        let sensitiveWriteRules = sensitiveURLs.map {
            "(deny file-write* (\($0.hasDirectoryPath ? "subpath" : "literal") \(sandboxString($0.path))))"
        }.joined(separator: "\n")
        let sandboxDirectoryFilters = sandboxAliasedPaths(for: directory).map {
            "  (subpath \(sandboxString($0)))"
        }.joined(separator: "\n")

        let profile = """
        (version 1)
        (deny default)
        (allow process*)
        (allow signal (target self))
        (allow sysctl-read)
        (allow mach-lookup)
        (allow network*)

        ; Commands may inspect ordinary local context needed to complete the owner's
        ; current request. Writes remain limited to configured roots. Explicit
        ; credential stores and discovered secret files are denied below.
        (allow file-read*)

        (allow file-write*
        \(writeRootFilters)
        \(sandboxDirectoryFilters)
          (literal "/dev/null"))

        ; Explicit secret files inside an otherwise allowed project stay denied.
        (deny file-read* (subpath "/Library/Keychains"))
        (deny file-read* (subpath "/private/etc/ssh"))
        \(sensitiveReadRules)
        \(sensitiveWriteRules)
        """
        let profileURL = directory.appendingPathComponent("command.sb")
        try Data(profile.utf8).write(to: profileURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: profileURL.path)
        return CommandSandbox(directory: directory, scriptURL: scriptURL, profileURL: profileURL)
    }

    private func discoveredSensitiveURLs() throws -> [URL] {
        var results: [URL] = []
        var seen = Set<String>()
        let keys: [URLResourceKey] = [.isDirectoryKey]
        for root in allowedRoots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let url as URL in enumerator {
                let canonical = url.resolvingSymlinksInPath()
                if isSensitive(canonical) {
                    let isDirectory = (try? canonical.resourceValues(forKeys: Set(keys)).isDirectory) == true
                    let protectedURL = URL(fileURLWithPath: canonical.path, isDirectory: isDirectory)
                    if seen.insert(canonical.path).inserted { results.append(protectedURL) }
                    if isDirectory {
                        enumerator.skipDescendants()
                    }
                }
                if results.count >= 500 { throw ToolRegistryError.commandRejected }
            }
        }
        return results
    }

    private func sandboxString(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func sandboxAliasedPaths(for url: URL) -> [String] {
        var paths = [url.path]
        if url.path.hasPrefix("/var/") { paths.append("/private" + url.path) }
        if url.path.hasPrefix("/tmp/") { paths.append("/private" + url.path) }
        if url.path.hasPrefix("/private/var/") { paths.append(String(url.path.dropFirst(8))) }
        if url.path.hasPrefix("/private/tmp/") { paths.append(String(url.path.dropFirst(8))) }
        return Array(Set(paths)).sorted()
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func sanitizedEnvironment() -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        return [
            "HOME": homeURL.path,
            "USER": NSUserName(),
            "LOGNAME": NSUserName(),
            "SHELL": "/bin/zsh",
            // `-l` is required for the command contract. Redirecting ZDOTDIR
            // keeps a login shell from re-importing API keys in ~/.zprofile.
            "ZDOTDIR": "/var/empty",
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": NSTemporaryDirectory(),
            "LANG": inherited["LANG"] ?? "en_US.UTF-8"
        ]
    }
}
