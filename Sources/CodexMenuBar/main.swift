import AppKit
import Foundation

struct CommandResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

@discardableResult
func runCommand(_ executable: String, _ arguments: [String], cwd: String? = nil, timeout: TimeInterval = 8) -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let cwd {
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
    }

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    do {
        try process.run()
    } catch {
        return CommandResult(exitCode: 127, stdout: "", stderr: String(describing: error))
    }

    let semaphore = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in semaphore.signal() }
    if semaphore.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        _ = semaphore.wait(timeout: .now() + 1)
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
        let timeoutText = stderrText.isEmpty ? "Timed out" : "\(stderrText)\nTimed out"
        return CommandResult(
            exitCode: 124,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: timeoutText
        )
    }

    let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
    return CommandResult(
        exitCode: process.terminationStatus,
        stdout: String(data: stdoutData, encoding: .utf8) ?? "",
        stderr: String(data: stderrData, encoding: .utf8) ?? ""
    )
}

func homePath(_ suffix: String) -> String {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(suffix).path
}

func expandedHomePath(_ path: String) -> String {
    if path == "~" {
        return FileManager.default.homeDirectoryForCurrentUser.path
    }
    if path.hasPrefix("~/") {
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(String(path.dropFirst(2)))
            .path
    }
    return path
}

func isLoopbackHost(_ host: String) -> Bool {
    let trimmed = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    let normalized = trimmed.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    if normalized == "localhost" || normalized.hasSuffix(".localhost") {
        return true
    }
    if normalized == "::1" || normalized == "0:0:0:0:0:0:0:1" {
        return true
    }
    if normalized.hasPrefix("127.") {
        let parts = normalized.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { part in
            guard let value = Int(part) else { return false }
            return (0...255).contains(value)
        }
    }
    return false
}

func isAllowedLocalHTTPURL(_ components: URLComponents) -> Bool {
    guard let scheme = components.scheme?.lowercased(),
          ["http", "https"].contains(scheme),
          let host = components.host else {
        return false
    }
    return isLoopbackHost(host)
}

func ensureDirectory(_ path: String) {
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

func abbreviatePath(_ path: String?) -> String {
    guard let path, !path.isEmpty else { return "Unknown folder" }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path == home { return "~" }
    if path.hasPrefix(home + "/") {
        return "~" + path.dropFirst(home.count)
    }
    return path
}

func nowDate() -> Date {
    Date()
}

private let runtimeLogQueue = DispatchQueue(label: "codex-menu-bar.runtime-log", qos: .utility)

func runtimeLog(_ message: String) {
    runtimeLogQueue.async {
        let directory = homePath(".codex-menu-bar")
        ensureDirectory(directory)
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let path = "\(directory)/runtime.log"
        if FileManager.default.fileExists(atPath: path),
           let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            if let data = line.data(using: .utf8) {
                try? handle.write(contentsOf: data)
            }
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

struct TrackedServer: Codable {
    var id: String
    var name: String
    var cwd: String?
    var startCommand: String?
    var port: Int?
}

struct ServerRegistryData: Codable {
    var servers: [TrackedServer] = []
    var hiddenDiscoveredIDs: [String] = []
}

final class ServerRegistry: @unchecked Sendable {
    private let directoryPath = homePath(".codex-menu-bar")
    private let filePath = homePath(".codex-menu-bar/servers.json")

    func load() -> ServerRegistryData {
        ensureDirectory(directoryPath)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else {
            return ServerRegistryData()
        }
        return (try? JSONDecoder().decode(ServerRegistryData.self, from: data)) ?? ServerRegistryData()
    }

    func save(_ registry: ServerRegistryData) {
        ensureDirectory(directoryPath)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(registry) else { return }
        try? data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
    }

    func upsert(_ server: WebServer) {
        var registry = load()
        let tracked = TrackedServer(
            id: server.id,
            name: server.name,
            cwd: server.cwd,
            startCommand: server.startCommand,
            port: server.port
        )
        if let index = registry.servers.firstIndex(where: { $0.id == server.id }) {
            registry.servers[index] = tracked
        } else {
            registry.servers.append(tracked)
        }
        save(registry)
    }

    func remove(id: String) {
        var registry = load()
        registry.servers.removeAll { $0.id == id }
        if !registry.hiddenDiscoveredIDs.contains(id) {
            registry.hiddenDiscoveredIDs.append(id)
        }
        save(registry)
    }
}

struct WebServer: Hashable {
    var id: String
    var name: String
    var port: Int?
    var pid: Int?
    var command: String
    var cwd: String?
    var startCommand: String?
    var isRunning: Bool

    var urlString: String? {
        guard let port else { return nil }
        return "http://localhost:\(port)"
    }

    var displayTitle: String {
        if let port {
            return "\(name) :\(port)"
        }
        return name
    }
}

struct LaunchCommandSpec {
    var executable: String
    var arguments: [String]
}

private let generatedStartScripts: Set<String> = ["dev", "start", "serve"]

func structuredStartCommand(_ command: String) -> LaunchCommandSpec? {
    let parts = command.split(separator: " ").map(String.init)
    guard !parts.isEmpty else { return nil }

    switch parts[0] {
    case "npm", "pnpm", "bun":
        guard parts.count == 3,
              parts[1] == "run",
              generatedStartScripts.contains(parts[2]) else {
            return nil
        }
        return LaunchCommandSpec(executable: "/usr/bin/env", arguments: parts)
    case "yarn":
        guard parts.count == 2,
              generatedStartScripts.contains(parts[1]) else {
            return nil
        }
        return LaunchCommandSpec(executable: "/usr/bin/env", arguments: parts)
    case "python3":
        guard parts.count == 4,
              parts[1] == "manage.py",
              parts[2] == "runserver",
              isLoopbackRunserverTarget(parts[3]) else {
            return nil
        }
        return LaunchCommandSpec(executable: "/usr/bin/env", arguments: parts)
    default:
        return nil
    }
}

func startCommandRequiresConfirmation(_ command: String) -> Bool {
    structuredStartCommand(command) == nil
}

private func isLoopbackRunserverTarget(_ value: String) -> Bool {
    let prefix = "127.0.0.1:"
    guard value.hasPrefix(prefix),
          let port = Int(value.dropFirst(prefix.count)) else {
        return false
    }
    return (1...65535).contains(port)
}

struct LsofEndpoint {
    var pid: Int
    var commandName: String
    var port: Int
}

final class ServerCollector: @unchecked Sendable {
    private let registry = ServerRegistry()

    func collect() -> [WebServer] {
        let registryData = registry.load()
        let hidden = Set(registryData.hiddenDiscoveredIDs)
        let discovered = discoverRunningServers().filter { !hidden.contains($0.id) }
        var byID: [String: WebServer] = [:]

        for server in discovered {
            byID[server.id] = server
        }

        for tracked in registryData.servers {
            if var existing = byID[tracked.id] {
                existing.name = tracked.name
                existing.startCommand = tracked.startCommand ?? existing.startCommand
                existing.cwd = tracked.cwd ?? existing.cwd
                byID[tracked.id] = existing
            } else {
                byID[tracked.id] = WebServer(
                    id: tracked.id,
                    name: tracked.name,
                    port: tracked.port,
                    pid: nil,
                    command: tracked.startCommand ?? "",
                    cwd: tracked.cwd,
                    startCommand: tracked.startCommand,
                    isRunning: false
                )
            }
        }

        return byID.values.sorted {
            if $0.isRunning != $1.isRunning { return $0.isRunning && !$1.isRunning }
            return $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
        }
    }

    private func discoverRunningServers() -> [WebServer] {
        let result = runCommand("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"], timeout: 8)
        guard result.exitCode == 0 else { return [] }

        let endpoints = parseLsof(result.stdout)
        var seen = Set<String>()
        var servers: [WebServer] = []

        for endpoint in endpoints {
            let command = commandLine(pid: endpoint.pid)
            let cwd = currentWorkingDirectory(pid: endpoint.pid)
            guard isLikelyProjectServer(commandName: endpoint.commandName, command: command, cwd: cwd) else {
                continue
            }

            let root = projectRoot(from: cwd) ?? cwd
            let startCommand = inferStartCommand(projectRoot: root, fallbackCommand: command, port: endpoint.port)
            let name = inferName(projectRoot: root, fallback: endpoint.commandName)
            let id = serverID(projectRoot: root, commandName: endpoint.commandName, port: endpoint.port)
            guard !seen.contains(id) else { continue }
            seen.insert(id)

            servers.append(WebServer(
                id: id,
                name: name,
                port: endpoint.port,
                pid: endpoint.pid,
                command: command,
                cwd: root,
                startCommand: startCommand,
                isRunning: true
            ))
        }

        return servers
    }

    private func parseLsof(_ output: String) -> [LsofEndpoint] {
        var endpoints: [LsofEndpoint] = []
        var currentPID: Int?
        var currentCommand = ""

        for rawLine in output.split(separator: "\n") {
            let line = String(rawLine)
            guard let prefix = line.first else { continue }
            let value = String(line.dropFirst())
            switch prefix {
            case "p":
                currentPID = Int(value)
                currentCommand = ""
            case "c":
                currentCommand = value
            case "n":
                guard let pid = currentPID, let port = parsePort(from: value) else { continue }
                endpoints.append(LsofEndpoint(pid: pid, commandName: currentCommand, port: port))
            default:
                continue
            }
        }

        var unique: [String: LsofEndpoint] = [:]
        for endpoint in endpoints {
            unique["\(endpoint.pid):\(endpoint.port)"] = endpoint
        }
        return Array(unique.values)
    }

    private func parsePort(from name: String) -> Int? {
        guard let colon = name.lastIndex(of: ":") else { return nil }
        let suffix = name[name.index(after: colon)...]
        let digits = suffix.prefix { $0.isNumber }
        return Int(digits)
    }

    private func commandLine(pid: Int) -> String {
        runCommand("/bin/ps", ["-p", String(pid), "-o", "command="], timeout: 3)
            .stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func currentWorkingDirectory(pid: Int) -> String? {
        let output = runCommand("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"], timeout: 3).stdout
        for line in output.split(separator: "\n") {
            if line.hasPrefix("n") {
                let path = String(line.dropFirst())
                return path.isEmpty ? nil : path
            }
        }
        return nil
    }

    private func isLikelyProjectServer(commandName: String, command: String, cwd: String?) -> Bool {
        let lowerName = commandName.lowercased()
        let lowerCommand = command.lowercased()
        let blockedNames = ["rapportd", "controlcenter", "ssh", "codex", "node_repl", "skycomputeruseclient"]
        if blockedNames.contains(where: { lowerName.contains($0) || lowerCommand.contains($0) }) {
            return false
        }

        let serverHints = [
            "node", "npm", "pnpm", "yarn", "bun", "deno", "vite", "next", "astro",
            "nuxt", "svelte", "remix", "serve", "python", "uvicorn", "gunicorn",
            "flask", "django", "ruby", "rails", "php"
        ]
        let hasServerCommand = serverHints.contains { lowerName.contains($0) || lowerCommand.contains($0) }
        guard hasServerCommand else { return false }

        guard let cwd, cwd != "/" else { return false }
        if projectRoot(from: cwd) != nil { return true }
        return cwd.contains("/Documents/") || cwd.contains("/Developer/") || cwd.contains("/Sites/")
    }

    private func projectRoot(from cwd: String?) -> String? {
        guard var path = cwd, !path.isEmpty else { return nil }
        let markers = [
            "package.json", "vite.config.ts", "vite.config.js", "next.config.js",
            "next.config.mjs", "astro.config.mjs", "svelte.config.js", "nuxt.config.ts",
            "pyproject.toml", "requirements.txt", "manage.py", "Gemfile", "composer.json"
        ]

        while path != "/" {
            for marker in markers {
                if FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent(marker).path) {
                    return path
                }
            }
            path = URL(fileURLWithPath: path).deletingLastPathComponent().path
        }
        return nil
    }

    private func inferName(projectRoot: String?, fallback: String) -> String {
        guard let projectRoot else { return fallback }
        let packageURL = URL(fileURLWithPath: projectRoot).appendingPathComponent("package.json")
        if let data = try? Data(contentsOf: packageURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = object["name"] as? String,
           !name.isEmpty {
            return name
        }
        return URL(fileURLWithPath: projectRoot).lastPathComponent
    }

    private func inferStartCommand(projectRoot: String?, fallbackCommand: String, port: Int) -> String? {
        guard let projectRoot else { return sanitizedFallbackCommand(fallbackCommand) }

        let packageURL = URL(fileURLWithPath: projectRoot).appendingPathComponent("package.json")
        if let data = try? Data(contentsOf: packageURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let scripts = object["scripts"] as? [String: Any] {
            let manager = packageManager(projectRoot: projectRoot)
            for script in ["dev", "start", "serve"] where scripts[script] != nil {
                if manager == "yarn" {
                    return "yarn \(script)"
                }
                return "\(manager) run \(script)"
            }
        }

        if FileManager.default.fileExists(atPath: URL(fileURLWithPath: projectRoot).appendingPathComponent("manage.py").path) {
            return "python3 manage.py runserver 127.0.0.1:\(port)"
        }

        return sanitizedFallbackCommand(fallbackCommand)
    }

    private func packageManager(projectRoot: String) -> String {
        let root = URL(fileURLWithPath: projectRoot)
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("pnpm-lock.yaml").path) { return "pnpm" }
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("yarn.lock").path) { return "yarn" }
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("bun.lock").path) { return "bun" }
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("bun.lockb").path) { return "bun" }
        return "npm"
    }

    private func sanitizedFallbackCommand(_ command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count < 400 else { return nil }
        return trimmed
    }

    private func serverID(projectRoot: String?, commandName: String, port: Int) -> String {
        let rootPart = projectRoot ?? commandName
        return "\(rootPart)|\(port)"
    }
}

struct CodexLimit: Decodable {
    var usedPercent: Int
    var windowMinutes: Int
    var resetAt: Date

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case windowMinutes = "window_minutes"
        case resetAt = "reset_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usedPercent = try container.decode(Int.self, forKey: .usedPercent)
        windowMinutes = try container.decode(Int.self, forKey: .windowMinutes)
        let resetEpoch = try container.decode(TimeInterval.self, forKey: .resetAt)
        resetAt = Date(timeIntervalSince1970: resetEpoch)
    }
}

struct CodexRateLimits: Decodable {
    var primary: CodexLimit?
    var secondary: CodexLimit?
}

struct CodexRateLimitEvent: Decodable {
    var planType: String?
    var rateLimits: CodexRateLimits

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimits = "rate_limits"
    }
}

struct CodexUsage {
    var planType: String?
    var primary: CodexLimit?
    var secondary: CodexLimit?
    var observedAt: Date?
}

struct RemoteHelperConfig: Codable, Hashable {
    var name: String?
    var matchContains: [String]
    var launchAgentLabel: String?
    var remoteControlURL: String?
}

struct AppConfig: Decodable {
    var remoteHelpers: [RemoteHelperConfig] = []

    enum CodingKeys: String, CodingKey {
        case remoteHelpers
    }

    init(remoteHelpers: [RemoteHelperConfig] = []) {
        self.remoteHelpers = remoteHelpers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        remoteHelpers = try container.decodeIfPresent([RemoteHelperConfig].self, forKey: .remoteHelpers) ?? []
    }

    static func load() -> AppConfig {
        let environment = ProcessInfo.processInfo.environment
        let path = environment["CODEX_MENU_BAR_CONFIG"].map(expandedHomePath)
            ?? homePath(".codex-menu-bar/config.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return AppConfig()
        }
        do {
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            runtimeLog("config decode failed path=\(path) error=\(error)")
            return AppConfig()
        }
    }
}

struct ManagedRemoteConnection: Decodable {
    var hostId: String
    var displayName: String?
    var source: String?
    var alias: String?
    var hostname: String?
    var sshPort: Int?
    var identity: String?
}

struct RemoteProjectRecord: Decodable {
    var id: String
    var hostId: String
    var remotePath: String
    var label: String
}

struct CodexGlobalState: Decodable {
    var managedRemoteConnections: [ManagedRemoteConnection]?
    var remoteProjects: [RemoteProjectRecord]?
    var remoteAutoConnectByHostID: [String: Bool]?
    var selectedRemoteHostID: String?

    enum CodingKeys: String, CodingKey {
        case managedRemoteConnections = "codex-managed-remote-connections"
        case remoteProjects = "remote-projects"
        case remoteAutoConnectByHostID = "remote-connection-auto-connect-by-host-id"
        case selectedRemoteHostID = "selected-remote-host-id"
    }
}

struct RemoteConnectionStatus: Hashable {
    var hostId: String
    var displayName: String
    var alias: String?
    var hostname: String?
    var sshUser: String?
    var sshPort: Int?
    var projectCount: Int
    var projectLabels: [String]
    var autoConnect: Bool
    var isSelected: Bool
    var tailscaleOnline: Bool?
    var tcpReachable: Bool?
    var sshAuthenticated: Bool?
    var remoteControlReachable: Bool?
    var remoteHelper: RemoteHelperConfig?
    var statusTitle: String
    var detail: String
    var authURL: String?

    var target: String {
        alias ?? hostname ?? displayName
    }

    var hasRemoteHelper: Bool { remoteHelper != nil }
}

struct SSHSettings {
    var hostname: String?
    var user: String?
    var port: Int?
}

final class RemoteProjectCollector: @unchecked Sendable {
    private let globalStatePath = homePath(".codex/.codex-global-state.json")
    private let sshProbeCacheSeconds: TimeInterval = 300
    private let config: AppConfig
    private var sshProbeCache: [String: (observedAt: Date, result: (ok: Bool?, message: String, authURL: String?))] = [:]

    init(config: AppConfig = .load()) {
        self.config = config
    }

    func collect() -> [RemoteConnectionStatus] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: globalStatePath)),
              let state = try? JSONDecoder().decode(CodexGlobalState.self, from: data) else {
            return []
        }

        let projectsByHost = Dictionary(grouping: state.remoteProjects ?? [], by: { $0.hostId })
        return (state.managedRemoteConnections ?? []).map { connection in
            diagnose(
                connection: connection,
                projects: projectsByHost[connection.hostId] ?? [],
                autoConnect: state.remoteAutoConnectByHostID?[connection.hostId] ?? false,
                isSelected: state.selectedRemoteHostID == connection.hostId
            )
        }.sorted {
            if $0.isSelected != $1.isSelected { return $0.isSelected && !$1.isSelected }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private func diagnose(
        connection: ManagedRemoteConnection,
        projects: [RemoteProjectRecord],
        autoConnect: Bool,
        isSelected: Bool
    ) -> RemoteConnectionStatus {
        let displayName = connection.displayName ?? connection.alias ?? connection.hostname ?? connection.hostId
        let target = connection.alias ?? connection.hostname ?? displayName
        let settings = sshSettings(for: target)
        let hostname = connection.hostname ?? settings.hostname
        let port = connection.sshPort ?? settings.port ?? 22
        let remoteHelper = remoteHelper(for: connection, displayName: displayName)
        let tailscaleOnline = tailscaleOnline(alias: connection.alias ?? displayName, hostname: hostname)
        let tcpReachable = hostname.flatMap { host in
            runCommand("/usr/bin/nc", ["-G", "3", "-z", host, String(port)], timeout: 5).exitCode == 0
        }
        let sshProbe = cachedSSHAuthProbe(target: target)
        let remoteControlReachable = remoteHelper.flatMap(remoteControlReachable)
        let status = statusText(
            tailscaleOnline: tailscaleOnline,
            tcpReachable: tcpReachable,
            sshAuthenticated: sshProbe.ok,
            remoteControlReachable: remoteControlReachable,
            authURL: sshProbe.authURL,
            sshError: sshProbe.message
        )

        return RemoteConnectionStatus(
            hostId: connection.hostId,
            displayName: displayName,
            alias: connection.alias,
            hostname: hostname,
            sshUser: settings.user,
            sshPort: port,
            projectCount: projects.count,
            projectLabels: projects.map(\.label).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
            autoConnect: autoConnect,
            isSelected: isSelected,
            tailscaleOnline: tailscaleOnline,
            tcpReachable: tcpReachable,
            sshAuthenticated: sshProbe.ok,
            remoteControlReachable: remoteControlReachable,
            remoteHelper: remoteHelper,
            statusTitle: status.title,
            detail: status.detail,
            authURL: sshProbe.authURL
        )
    }

    private func sshSettings(for target: String) -> SSHSettings {
        let result = runCommand("/usr/bin/ssh", ["-G", target], timeout: 4)
        guard result.exitCode == 0 else { return SSHSettings() }
        var settings = SSHSettings()
        for line in result.stdout.components(separatedBy: .newlines) {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "hostname":
                settings.hostname = parts[1]
            case "user":
                settings.user = parts[1]
            case "port":
                settings.port = Int(parts[1])
            default:
                continue
            }
        }
        return settings
    }

    private func sshAuthProbe(target: String) -> (ok: Bool?, message: String, authURL: String?) {
        let result = runCommand(
            "/usr/bin/ssh",
            [
                "-o", "BatchMode=yes",
                "-o", "NumberOfPasswordPrompts=0",
                "-o", "ConnectTimeout=6",
                target,
                "true"
            ],
            timeout: 9
        )
        let output = [result.stdout, result.stderr].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if result.exitCode == 0 {
            return (true, "SSH command probe succeeded.", nil)
        }
        if result.exitCode == 124 {
            let message = cleanProbeMessage(output)
            return (false, message.isEmpty ? "SSH command probe timed out." : message, firstURL(in: output))
        }
        return (false, cleanProbeMessage(output), firstURL(in: output))
    }

    private func cachedSSHAuthProbe(target: String, force: Bool = false) -> (ok: Bool?, message: String, authURL: String?) {
        if !force,
           let cached = sshProbeCache[target],
           Date().timeIntervalSince(cached.observedAt) < sshProbeCacheSeconds {
            return cached.result
        }
        let result = sshAuthProbe(target: target)
        sshProbeCache[target] = (Date(), result)
        return result
    }

    private func tailscaleOnline(alias: String?, hostname: String?) -> Bool? {
        guard let tailscale = tailscaleExecutable() else { return nil }
        let result = runCommand(tailscale, ["status", "--json"], timeout: 5)
        guard result.exitCode == 0,
              let data = result.stdout.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let peers = object["Peer"] as? [String: Any] else {
            return nil
        }

        let wanted = [alias, hostname]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        for peerValue in peers.values {
            guard let peer = peerValue as? [String: Any] else { continue }
            let hostName = (peer["HostName"] as? String)?.lowercased()
            let dnsName = (peer["DNSName"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            let ips = (peer["TailscaleIPs"] as? [String])?.map { $0.lowercased() } ?? []
            let names = [hostName, dnsName].compactMap { $0 } + ips
            if wanted.contains(where: { wantedName in names.contains(where: { $0 == wantedName || $0.hasPrefix("\(wantedName).") }) }) {
                return peer["Online"] as? Bool
            }
        }
        return nil
    }

    private func tailscaleExecutable() -> String? {
        let bundled = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        if FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        let result = runCommand("/usr/bin/which", ["tailscale"], timeout: 2)
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.exitCode == 0 && !path.isEmpty ? path : nil
    }

    private func remoteControlReachable(for helper: RemoteHelperConfig) -> Bool {
        guard let urlString = helper.remoteControlURL,
              let components = URLComponents(string: urlString),
              isAllowedLocalHTTPURL(components),
              let host = components.host else {
            return false
        }
        if let port = components.port {
            let nc = runCommand("/usr/bin/nc", ["-G", "2", "-z", host, String(port)], timeout: 4)
            guard nc.exitCode == 0 else { return false }
        }
        let curl = runCommand("/usr/bin/curl", ["--max-time", "4", "-sS", urlString], timeout: 6)
        let output = curl.stdout + curl.stderr
        return output.contains("Connection header did not include 'upgrade'") || curl.exitCode == 0
    }

    private func remoteHelper(for connection: ManagedRemoteConnection, displayName: String) -> RemoteHelperConfig? {
        let values: [String?] = [connection.hostId, displayName, connection.alias, connection.hostname]
        let normalizedValues = values
            .compactMap { $0?.lowercased() }
        return config.remoteHelpers.first { helper in
            helper.matchContains
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
                .contains { needle in
                    normalizedValues.contains { $0.contains(needle) }
                }
        }
    }

    private func statusText(
        tailscaleOnline: Bool?,
        tcpReachable: Bool?,
        sshAuthenticated: Bool?,
        remoteControlReachable: Bool?,
        authURL: String?,
        sshError: String
    ) -> (title: String, detail: String) {
        if remoteControlReachable == true && sshAuthenticated == true {
            return ("Connected", "Remote control and SSH probe are both responding.")
        }
        if remoteControlReachable == true && authURL != nil {
            return ("Remote control up; SSH check needed", "Remote control is reachable, but SSH refresh requires the Tailscale browser check.")
        }
        if remoteControlReachable == true && sshAuthenticated == false {
            return ("Remote control up; SSH refresh failed", sshError)
        }
        if tailscaleOnline == false {
            return ("Tailscale offline", "The remote host is not online in Tailscale.")
        }
        if tcpReachable == false {
            return ("SSH port not reachable", "The host is online, but TCP port 22 is not reachable.")
        }
        if authURL != nil {
            return ("Needs Tailscale SSH check", "Open the Tailscale check link, then refresh this connection.")
        }
        if sshAuthenticated == false {
            return ("SSH refresh failed", sshError)
        }
        if remoteControlReachable == false {
            return ("Remote control not reachable", "The SSH tunnel is not forwarding to the Codex remote-control service.")
        }
        return ("Unknown", "No remote status could be confirmed.")
    }

    private func cleanProbeMessage(_ text: String) -> String {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("# To authenticate, visit:") }
        return lines.prefix(2).joined(separator: " ")
    }

    private func firstURL(in text: String) -> String? {
        guard let range = text.range(of: #"https?://[^\s]+"#, options: .regularExpression) else {
            return nil
        }
        return String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,)"))
    }

    func refreshConnection(_ connection: RemoteConnectionStatus) {
        runtimeLog("refresh remote connection hostId=\(connection.hostId) target=\(connection.target)")
        if let label = connection.remoteHelper?.launchAgentLabel {
            let plist = homePath("Library/LaunchAgents/\(label).plist")
            if FileManager.default.fileExists(atPath: plist),
               runCommand("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"], timeout: 3).exitCode != 0 {
                _ = runCommand("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plist], timeout: 5)
            }
            _ = runCommand("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(label)"], timeout: 8)
        }
        _ = cachedSSHAuthProbe(target: connection.target, force: true)
    }
}

final class CodexUsageCollector: @unchecked Sendable {
    private let databasePath = homePath(".codex/logs_2.sqlite")

    func collect() -> CodexUsage? {
        guard FileManager.default.fileExists(atPath: databasePath) else { return nil }
        let query = """
        select ts || char(31) || feedback_log_body
        from logs
        where feedback_log_body like '%"type":"codex.rate_limits"%'
          and feedback_log_body not like '%exec_command%'
        order by ts desc, ts_nanos desc
        limit 1;
        """
        let result = runCommand("/usr/bin/sqlite3", [databasePath, query], timeout: 5)
        guard result.exitCode == 0, !result.stdout.isEmpty else { return nil }
        let parts = result.stdout.components(separatedBy: "\u{1F}")
        let observedAt = parts.first.flatMap { TimeInterval($0.trimmingCharacters(in: .whitespacesAndNewlines)) }.map {
            Date(timeIntervalSince1970: $0)
        }
        let body = parts.dropFirst().joined(separator: "\u{1F}")
        guard let json = extractRateLimitJSON(from: body),
              let data = json.data(using: .utf8),
              let event = try? JSONDecoder().decode(CodexRateLimitEvent.self, from: data) else {
            return nil
        }
        return CodexUsage(
            planType: event.planType,
            primary: event.rateLimits.primary,
            secondary: event.rateLimits.secondary,
            observedAt: observedAt
        )
    }

    private func extractRateLimitJSON(from body: String) -> String? {
        guard let marker = body.range(of: "{\"type\":\"codex.rate_limits\"") else { return nil }
        let suffix = String(body[marker.lowerBound...])
        var depth = 0
        var inString = false
        var escaped = false

        for (index, character) in suffix.enumerated() {
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if character == "\"" {
                inString.toggle()
                continue
            }
            if inString { continue }
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 {
                    let end = suffix.index(suffix.startIndex, offsetBy: index)
                    return String(suffix[...end])
                }
            }
        }
        return nil
    }
}

final class CaffeinateController: @unchecked Sendable {
    let label = "codex.caffeinate"

    func isOn() -> Bool {
        let launchctl = runCommand("/bin/launchctl", ["list", label], timeout: 3)
        if launchctl.exitCode == 0 { return true }
        let pgrep = runCommand("/usr/bin/pgrep", ["-x", "caffeinate"], timeout: 3)
        return pgrep.exitCode == 0 && !pgrep.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func turnOn() {
        _ = runCommand("/bin/launchctl", ["submit", "-l", label, "--", "/usr/bin/caffeinate", "-dims"], timeout: 5)
    }

    func turnOff() {
        _ = runCommand("/bin/launchctl", ["remove", label], timeout: 5)
        _ = runCommand("/usr/bin/pkill", ["-x", "caffeinate"], timeout: 5)
    }
}

final class ClosedLidAwakeController: @unchecked Sendable {
    func isOn() -> Bool {
        let result = runCommand("/usr/bin/pmset", ["-g", "live"], timeout: 3)
        guard result.exitCode == 0 else { return false }
        for line in result.stdout.components(separatedBy: .newlines) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, parts[0] == "SleepDisabled" {
                return parts[1] == "1"
            }
        }
        return false
    }

    func turnOn() {
        setSleepDisabled(true)
    }

    func turnOff() {
        setSleepDisabled(false)
    }

    private func setSleepDisabled(_ enabled: Bool) {
        let value = enabled ? "1" : "0"
        let direct = runCommand("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", value], timeout: 5)
        if direct.exitCode == 0 { return }

        let script = "do shell script \"/usr/bin/pmset -a disablesleep \(value)\" with administrator privileges"
        _ = runCommand("/usr/bin/osascript", ["-e", script], timeout: 120)
    }
}

struct DashboardSnapshot {
    var servers: [WebServer]
    var remoteConnections: [RemoteConnectionStatus]
    var usage: CodexUsage?
    var caffeinateOn: Bool
    var closedLidAwakeOn: Bool
    var generatedAt: Date

    static let empty = DashboardSnapshot(servers: [], remoteConnections: [], usage: nil, caffeinateOn: false, closedLidAwakeOn: false, generatedAt: .distantPast)
}

final class ActionButton: NSButton {
    var handler: (() -> Void)?

    convenience init(title: String, handler: @escaping () -> Void) {
        self.init(title: title, target: nil, action: nil)
        self.handler = handler
        self.target = self
        self.action = #selector(runHandler)
        self.bezelStyle = .rounded
        self.controlSize = .small
        self.font = NSFont.systemFont(ofSize: 12)
    }

    @objc private func runHandler() {
        handler?()
    }
}

final class DashboardController: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private static let refreshInterval: TimeInterval = 60
    private let openMenuOnLaunch = CommandLine.arguments.contains("--open-menu-on-launch")
    private var statusItem: NSStatusItem?
    private var currentMenu: NSMenu?
    private var popover: NSPopover?
    private let worker = DispatchQueue(label: "codex-menu-bar.worker", qos: .userInitiated)
    private let caffeinateWorker = DispatchQueue(label: "codex-menu-bar.caffeinate", qos: .userInitiated)
    private let closedLidWorker = DispatchQueue(label: "codex-menu-bar.closed-lid", qos: .userInitiated)
    private let serverCollector = ServerCollector()
    private let remoteProjectCollector = RemoteProjectCollector()
    private let usageCollector = CodexUsageCollector()
    private let caffeinate = CaffeinateController()
    private let closedLidAwake = ClosedLidAwakeController()
    private let registry = ServerRegistry()
    private var snapshot = DashboardSnapshot.empty
    private var timer: Timer?
    private var isRefreshing = false
    private var pendingPopoverUpdateAfterRefresh = false
    private var started = false

    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        start()
    }

    @MainActor func start() {
        guard !started else { return }
        started = true
        runtimeLog("start openMenuOnLaunch=\(openMenuOnLaunch)")
        NSApplication.shared.setActivationPolicy(.accessory)
        configureStatusItem()
        refresh()
        timer = Timer.scheduledTimer(timeInterval: Self.refreshInterval, target: self, selector: #selector(refreshNow), userInfo: nil, repeats: true)
        if openMenuOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                runtimeLog("openMenuOnLaunch buttonExists=\(self?.statusItem?.button != nil)")
                self?.showDashboardPopover()
            }
        }
    }

    @MainActor private func configureStatusItem() {
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            statusItem?.autosaveName = "CodexDashboardStatusItem"
            statusItem?.isVisible = true
            if #available(macOS 10.12, *) {
                statusItem?.behavior = [.removalAllowed]
            }
            runtimeLog("created status item visible=\(statusItem?.isVisible ?? false)")
        }
        guard let button = statusItem?.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked)
        button.toolTip = "Codex Dashboard"
        if let image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Codex Dashboard") {
            image.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.title = ""
        } else {
            button.title = "CX"
            button.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        }
        runtimeLog("configured status button frame=\(button.frame) window=\(String(describing: button.window?.frame))")
    }

    @MainActor private func refresh(updateOpenPopover: Bool = false) {
        if updateOpenPopover {
            pendingPopoverUpdateAfterRefresh = true
        }
        guard !isRefreshing else { return }
        isRefreshing = true
        let serverCollector = serverCollector
        let remoteProjectCollector = remoteProjectCollector
        let usageCollector = usageCollector
        let caffeinate = caffeinate
        let closedLidAwake = closedLidAwake
        worker.async { [weak self] in
            let next = DashboardSnapshot(
                servers: serverCollector.collect(),
                remoteConnections: remoteProjectCollector.collect(),
                usage: usageCollector.collect(),
                caffeinateOn: caffeinate.isOn(),
                closedLidAwakeOn: closedLidAwake.isOn(),
                generatedAt: nowDate()
            )
            DispatchQueue.main.async {
                guard let self else { return }
                self.snapshot = next
                self.isRefreshing = false
                let shouldUpdateOpenPopover = self.pendingPopoverUpdateAfterRefresh
                self.pendingPopoverUpdateAfterRefresh = false
                if self.currentMenu != nil {
                    self.rebuildMenu()
                }
                if shouldUpdateOpenPopover {
                    self.refreshPopoverContentIfShown()
                }
            }
        }
    }

    @MainActor private func updatePowerState(caffeinateOn: Bool? = nil, closedLidAwakeOn: Bool? = nil) {
        if let caffeinateOn {
            snapshot.caffeinateOn = caffeinateOn
        }
        if let closedLidAwakeOn {
            snapshot.closedLidAwakeOn = closedLidAwakeOn
        }
        snapshot.generatedAt = nowDate()
        if currentMenu != nil {
            rebuildMenu()
        }
        refreshPopoverContentIfShown()
    }

    @MainActor private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        addHeader("Codex Dashboard", to: menu)
        menu.addItem(disabledItem("Updated \(timeOnly(snapshot.generatedAt))"))
        menu.addItem(.separator())

        addUsageSection(to: menu)
        menu.addItem(.separator())

        addPowerSection(to: menu)
        menu.addItem(.separator())

        addRemoteProjectsSection(to: menu)
        menu.addItem(.separator())

        addServersSection(to: menu)
        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "Refresh now", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.isEnabled = true
        menu.addItem(refreshItem)

        let openConfig = NSMenuItem(title: "Open registry file", action: #selector(openRegistry), keyEquivalent: "")
        openConfig.target = self
        openConfig.isEnabled = true
        menu.addItem(openConfig)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Codex Dashboard", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        quit.isEnabled = true
        menu.addItem(quit)

        currentMenu = menu
    }

    @MainActor func showDashboardPopover() {
        guard let button = statusItem?.button else { return }
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = makeDashboardViewController()
        self.popover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    @MainActor private func makeDashboardViewController() -> NSViewController {
        let viewController = NSViewController()
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        root.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 360)
        ])

        root.addArrangedSubview(label("Codex Dashboard", font: .boldSystemFont(ofSize: 15)))
        root.addArrangedSubview(label("Updated \(timeOnly(snapshot.generatedAt))", color: .secondaryLabelColor))
        root.addArrangedSubview(separator())

        addUsageViews(to: root)
        root.addArrangedSubview(separator())
        addPowerViews(to: root)
        root.addArrangedSubview(separator())
        addRemoteProjectViews(to: root)
        root.addArrangedSubview(separator())
        addServerViews(to: root)
        root.addArrangedSubview(separator())

        let footer = row()
        footer.addArrangedSubview(ActionButton(title: "Refresh") { [weak self] in
            Task { @MainActor in
                self?.refresh(updateOpenPopover: true)
            }
        })
        footer.addArrangedSubview(ActionButton(title: "Registry") { _ = NSWorkspace.shared.open(URL(fileURLWithPath: homePath(".codex-menu-bar/servers.json"))) })
        footer.addArrangedSubview(ActionButton(title: "Quit") { NSApplication.shared.terminate(nil) })
        root.addArrangedSubview(footer)

        viewController.view = content
        return viewController
    }

    @MainActor private func refreshPopoverContentIfShown() {
        guard let popover, popover.isShown else { return }
        popover.contentViewController = makeDashboardViewController()
    }

    @MainActor private func addUsageViews(to root: NSStackView) {
        root.addArrangedSubview(label("Codex Usage", font: .boldSystemFont(ofSize: 13)))
        guard let usage = snapshot.usage else {
            root.addArrangedSubview(label("No usage event found yet", color: .secondaryLabelColor))
            return
        }
        if let plan = usage.planType {
            root.addArrangedSubview(label("Plan: \(plan)"))
        }
        if let primary = usage.primary {
            root.addArrangedSubview(label(limitLine(label: "Primary window (\(shortWindowLabel(primary.windowMinutes)))", limit: primary)))
        }
        if let secondary = usage.secondary {
            root.addArrangedSubview(label(limitLine(label: "Week", limit: secondary)))
        }
        if let observedAt = usage.observedAt {
            root.addArrangedSubview(label("Observed \(relativeAge(observedAt)) ago", color: .secondaryLabelColor))
        }
    }

    @MainActor private func addPowerViews(to root: NSStackView) {
        root.addArrangedSubview(label("Power", font: .boldSystemFont(ofSize: 13)))

        let caffeinateRow = row()
        caffeinateRow.addArrangedSubview(label("Caffeinate"))
        caffeinateRow.addArrangedSubview(label(snapshot.caffeinateOn ? "On" : "Off", color: snapshot.caffeinateOn ? .systemGreen : .secondaryLabelColor))
        caffeinateRow.addArrangedSubview(ActionButton(title: snapshot.caffeinateOn ? "Turn off" : "Turn on") { [weak self] in
            Task { @MainActor in self?.toggleCaffeinateDirect() }
        })
        root.addArrangedSubview(caffeinateRow)

        let lidRow = row()
        lidRow.addArrangedSubview(label("Closed-lid awake"))
        lidRow.addArrangedSubview(label(snapshot.closedLidAwakeOn ? "On" : "Off", color: snapshot.closedLidAwakeOn ? .systemGreen : .secondaryLabelColor))
        lidRow.addArrangedSubview(ActionButton(title: snapshot.closedLidAwakeOn ? "Allow sleep" : "Keep awake") { [weak self] in
            Task { @MainActor in self?.toggleClosedLidAwakeDirect() }
        })
        root.addArrangedSubview(lidRow)
    }

    @MainActor private func addRemoteProjectViews(to root: NSStackView) {
        root.addArrangedSubview(label("Remote Projects", font: .boldSystemFont(ofSize: 13)))
        guard !snapshot.remoteConnections.isEmpty else {
            root.addArrangedSubview(label("No Codex remote connections configured", color: .secondaryLabelColor))
            return
        }

        for connection in snapshot.remoteConnections {
            let card = NSView()
            card.wantsLayer = true
            card.layer?.cornerRadius = 6
            card.layer?.borderWidth = 1
            card.layer?.borderColor = NSColor.separatorColor.cgColor
            card.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.45).cgColor
            let inner = NSStackView()
            inner.orientation = .vertical
            inner.alignment = .leading
            inner.spacing = 5
            inner.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(inner)
            NSLayoutConstraint.activate([
                inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
                inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
                inner.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
                inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8)
            ])

            inner.addArrangedSubview(label(remoteConnectionTitle(connection), font: .boldSystemFont(ofSize: 12)))
            inner.addArrangedSubview(label(connection.statusTitle, color: remoteStatusColor(connection)))
            inner.addArrangedSubview(label(connection.detail, color: .secondaryLabelColor))
            inner.addArrangedSubview(label(remoteConnectionMeta(connection), color: .secondaryLabelColor))
            if !connection.projectLabels.isEmpty {
                inner.addArrangedSubview(label(connection.projectLabels.prefix(6).joined(separator: ", "), color: .secondaryLabelColor))
            }

            let buttons = row()
            buttons.addArrangedSubview(ActionButton(title: "Refresh connection") { [weak self] in
                Task { @MainActor in self?.refreshRemoteConnectionDirect(connection) }
            })
            if let authURL = connection.authURL {
                buttons.addArrangedSubview(ActionButton(title: "Tailscale check") {
                    if let url = URL(string: authURL) {
                        NSWorkspace.shared.open(url)
                    }
                })
            }
            inner.addArrangedSubview(buttons)

            root.addArrangedSubview(card)
            card.widthAnchor.constraint(equalToConstant: 332).isActive = true
        }
    }

    @MainActor private func addServerViews(to root: NSStackView) {
        root.addArrangedSubview(label("Local Web Servers", font: .boldSystemFont(ofSize: 13)))
        guard !snapshot.servers.isEmpty else {
            root.addArrangedSubview(label("No project web servers detected", color: .secondaryLabelColor))
            return
        }
        for server in snapshot.servers {
            let card = NSView()
            card.wantsLayer = true
            card.layer?.cornerRadius = 6
            card.layer?.borderWidth = 1
            card.layer?.borderColor = NSColor.separatorColor.cgColor
            card.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.45).cgColor
            let inner = NSStackView()
            inner.orientation = .vertical
            inner.alignment = .leading
            inner.spacing = 5
            inner.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(inner)
            NSLayoutConstraint.activate([
                inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
                inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
                inner.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
                inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8)
            ])

            inner.addArrangedSubview(label(server.displayTitle, font: .boldSystemFont(ofSize: 12)))
            inner.addArrangedSubview(label(server.isRunning ? "Running, PID \(server.pid.map(String.init) ?? "?")" : "Stopped", color: server.isRunning ? .systemGreen : .secondaryLabelColor))
            inner.addArrangedSubview(label(abbreviatePath(server.cwd), color: .secondaryLabelColor))
            if let startCommand = server.startCommand {
                inner.addArrangedSubview(label("Start: \(startCommand)", color: .secondaryLabelColor))
            }

            let buttons = row()
            buttons.addArrangedSubview(ActionButton(title: "Open") { [weak self] in
                Task { @MainActor in self?.openServerDirect(server) }
            })
            buttons.addArrangedSubview(ActionButton(title: server.isRunning ? "Stop" : "Start") { [weak self] in
                Task { @MainActor in
                    server.isRunning ? self?.stopServerDirect(server) : self?.startServerDirect(server)
                }
            })
            buttons.addArrangedSubview(ActionButton(title: "Remove") { [weak self] in
                Task { @MainActor in self?.removeServerDirect(server) }
            })
            inner.addArrangedSubview(buttons)

            root.addArrangedSubview(card)
            card.widthAnchor.constraint(equalToConstant: 332).isActive = true
        }
    }

    @MainActor private func label(_ text: String, font: NSFont = .systemFont(ofSize: 12), color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingMiddle
        field.maximumNumberOfLines = 2
        return field
    }

    @MainActor private func row() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    @MainActor private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    @MainActor private func addUsageSection(to menu: NSMenu) {
        addHeader("Codex Usage", to: menu)
        guard let usage = snapshot.usage else {
            menu.addItem(disabledItem("No usage event found yet"))
            menu.addItem(disabledItem("Open Codex once to refresh limits"))
            return
        }

        if let plan = usage.planType, !plan.isEmpty {
            menu.addItem(disabledItem("Plan: \(plan)"))
        }
        if let primary = usage.primary {
            menu.addItem(disabledItem(limitLine(label: "Short window (\(shortWindowLabel(primary.windowMinutes)))", limit: primary)))
        } else {
            menu.addItem(disabledItem("Short window: unavailable"))
        }
        if let secondary = usage.secondary {
            menu.addItem(disabledItem(limitLine(label: "Week", limit: secondary)))
        } else {
            menu.addItem(disabledItem("Week: unavailable"))
        }
        if let observedAt = usage.observedAt {
            menu.addItem(disabledItem("Observed \(relativeAge(observedAt)) ago"))
        }
    }

    @MainActor private func addPowerSection(to menu: NSMenu) {
        addHeader("Power", to: menu)
        let caffeinateItem = NSMenuItem(
            title: snapshot.caffeinateOn ? "Turn caffeinate off" : "Turn caffeinate on",
            action: #selector(toggleCaffeinate),
            keyEquivalent: ""
        )
        caffeinateItem.target = self
        caffeinateItem.state = snapshot.caffeinateOn ? .on : .off
        caffeinateItem.isEnabled = true
        menu.addItem(caffeinateItem)

        let closedLidItem = NSMenuItem(
            title: snapshot.closedLidAwakeOn ? "Allow sleep when lid closes" : "Keep awake when lid closes",
            action: #selector(toggleClosedLidAwake),
            keyEquivalent: ""
        )
        closedLidItem.target = self
        closedLidItem.state = snapshot.closedLidAwakeOn ? .on : .off
        closedLidItem.isEnabled = true
        menu.addItem(closedLidItem)
    }

    @MainActor private func addRemoteProjectsSection(to menu: NSMenu) {
        addHeader("Remote Projects", to: menu)
        guard !snapshot.remoteConnections.isEmpty else {
            menu.addItem(disabledItem("No Codex remote connections configured"))
            return
        }

        for connection in snapshot.remoteConnections {
            let item = NSMenuItem(title: "\(remoteConnectionTitle(connection)) - \(connection.statusTitle)", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            submenu.addItem(disabledItem(connection.statusTitle))
            submenu.addItem(disabledItem(connection.detail))
            submenu.addItem(disabledItem(remoteConnectionMeta(connection)))
            if let hostname = connection.hostname {
                submenu.addItem(disabledItem("Host: \(hostname):\(connection.sshPort ?? 22)"))
            }
            if let user = connection.sshUser {
                submenu.addItem(disabledItem("User: \(user)"))
            }
            if !connection.projectLabels.isEmpty {
                submenu.addItem(disabledItem("Projects: \(connection.projectLabels.prefix(5).joined(separator: ", "))"))
            }
            submenu.addItem(.separator())

            let refresh = NSMenuItem(title: "Refresh connection", action: #selector(refreshRemoteConnection), keyEquivalent: "")
            refresh.target = self
            refresh.representedObject = connection
            refresh.isEnabled = true
            submenu.addItem(refresh)

            if let authURL = connection.authURL {
                let openAuth = NSMenuItem(title: "Open Tailscale SSH check", action: #selector(openRemoteAuthURL), keyEquivalent: "")
                openAuth.target = self
                openAuth.representedObject = authURL
                openAuth.isEnabled = true
                submenu.addItem(openAuth)
            }

            item.submenu = submenu
            menu.addItem(item)
        }
    }

    @MainActor private func addServersSection(to menu: NSMenu) {
        addHeader("Local Web Servers", to: menu)
        guard !snapshot.servers.isEmpty else {
            menu.addItem(disabledItem("No project web servers detected"))
            return
        }

        for server in snapshot.servers {
            let item = NSMenuItem(title: serverMenuTitle(server), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            submenu.addItem(disabledItem(server.isRunning ? "Running" : "Stopped"))
            if let pid = server.pid {
                submenu.addItem(disabledItem("PID \(pid)"))
            }
            submenu.addItem(disabledItem(abbreviatePath(server.cwd)))
            if let startCommand = server.startCommand, !startCommand.isEmpty {
                submenu.addItem(disabledItem("Start: \(startCommand)"))
            }
            submenu.addItem(.separator())

            if let url = server.urlString {
                let open = NSMenuItem(title: "Open \(url)", action: #selector(openServer), keyEquivalent: "")
                open.target = self
                open.representedObject = server
                open.isEnabled = server.isRunning
                submenu.addItem(open)
            }

            let start = NSMenuItem(title: "Start", action: #selector(startServer), keyEquivalent: "")
            start.target = self
            start.representedObject = server
            start.isEnabled = !server.isRunning && server.startCommand != nil && server.cwd != nil
            submenu.addItem(start)

            let stop = NSMenuItem(title: "Stop", action: #selector(stopServer), keyEquivalent: "")
            stop.target = self
            stop.representedObject = server
            stop.isEnabled = server.isRunning && server.pid != nil
            submenu.addItem(stop)

            let remove = NSMenuItem(title: "Remove from menu", action: #selector(removeServer), keyEquivalent: "")
            remove.target = self
            remove.representedObject = server
            remove.isEnabled = true
            submenu.addItem(remove)

            item.submenu = submenu
            menu.addItem(item)
        }
    }

    @MainActor private func addHeader(_ title: String, to menu: NSMenu) {
        let item = disabledItem(title)
        if #available(macOS 14, *) {
            item.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]
            )
        }
        menu.addItem(item)
    }

    @MainActor private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func serverMenuTitle(_ server: WebServer) -> String {
        let status = server.isRunning ? "On" : "Off"
        return "\(server.displayTitle) - \(status)"
    }

    private func remoteConnectionTitle(_ connection: RemoteConnectionStatus) -> String {
        var parts = [connection.displayName]
        if connection.isSelected {
            parts.append("selected")
        }
        if connection.autoConnect {
            parts.append("auto")
        }
        return parts.joined(separator: " ")
    }

    private func remoteConnectionMeta(_ connection: RemoteConnectionStatus) -> String {
        var parts = ["\(connection.projectCount) project\(connection.projectCount == 1 ? "" : "s")"]
        if let alias = connection.alias {
            parts.append("alias \(alias)")
        }
        if let tailscaleOnline = connection.tailscaleOnline {
            parts.append(tailscaleOnline ? "Tailscale online" : "Tailscale offline")
        }
        if connection.remoteControlReachable == true {
            parts.append("remote-control up")
        }
        return parts.joined(separator: " · ")
    }

    private func remoteStatusColor(_ connection: RemoteConnectionStatus) -> NSColor {
        if connection.statusTitle == "Connected" {
            return .systemGreen
        }
        if connection.statusTitle.contains("up") || connection.statusTitle.contains("check") {
            return .systemOrange
        }
        return .systemRed
    }

    private func limitLine(label: String, limit: CodexLimit) -> String {
        "\(label): \(limit.usedPercent)% used, resets \(resetText(limit.resetAt))"
    }

    private func shortWindowLabel(_ minutes: Int) -> String {
        if minutes == 240 { return "4h" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }

    private func resetText(_ date: Date) -> String {
        "\(timeAndDay(date)) (\(relativeUntil(date)))"
    }

    private func timeOnly(_ date: Date) -> String {
        guard date > .distantPast else { return "starting" }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func timeAndDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = Calendar.current.isDateInToday(date) ? .none : .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func relativeAge(_ date: Date) -> String {
        durationText(max(0, nowDate().timeIntervalSince(date)))
    }

    private func relativeUntil(_ date: Date) -> String {
        let seconds = date.timeIntervalSince(nowDate())
        if seconds <= 0 { return "now" }
        return "in \(durationText(seconds))"
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(0, Int(seconds / 60))
        if totalMinutes < 1 { return "<1m" }
        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60
        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(minutes)m"
    }

    @objc @MainActor private func refreshNow() {
        refresh(updateOpenPopover: true)
    }

    @objc @MainActor private func refreshRemoteConnection(_ sender: NSMenuItem) {
        guard let connection = sender.representedObject as? RemoteConnectionStatus else { return }
        refreshRemoteConnectionDirect(connection)
    }

    @MainActor private func refreshRemoteConnectionDirect(_ connection: RemoteConnectionStatus) {
        let collector = remoteProjectCollector
        worker.async { [weak self] in
            collector.refreshConnection(connection)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self?.refresh(updateOpenPopover: true)
            }
        }
    }

    @objc @MainActor private func openRemoteAuthURL(_ sender: NSMenuItem) {
        guard let urlString = sender.representedObject as? String,
              let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc @MainActor private func statusItemClicked() {
        showDashboardPopover()
    }

    @objc @MainActor private func toggleCaffeinate() {
        toggleCaffeinateDirect()
    }

    @MainActor private func toggleCaffeinateDirect() {
        let desiredState = !snapshot.caffeinateOn
        updatePowerState(caffeinateOn: desiredState)
        let caffeinate = caffeinate
        caffeinateWorker.async { [weak self] in
            if desiredState {
                caffeinate.turnOn()
            } else {
                caffeinate.turnOff()
            }
            let actualState = caffeinate.isOn()
            DispatchQueue.main.async {
                self?.updatePowerState(caffeinateOn: actualState)
            }
        }
    }

    @objc @MainActor private func toggleClosedLidAwake() {
        toggleClosedLidAwakeDirect()
    }

    @MainActor private func toggleClosedLidAwakeDirect() {
        let desiredState = !snapshot.closedLidAwakeOn
        updatePowerState(closedLidAwakeOn: desiredState)
        let closedLidAwake = closedLidAwake
        closedLidWorker.async { [weak self] in
            if desiredState {
                closedLidAwake.turnOn()
            } else {
                closedLidAwake.turnOff()
            }
            let actualState = closedLidAwake.isOn()
            DispatchQueue.main.async {
                self?.updatePowerState(closedLidAwakeOn: actualState)
            }
        }
    }

    @objc @MainActor private func openServer(_ sender: NSMenuItem) {
        guard let server = sender.representedObject as? WebServer else { return }
        openServerDirect(server)
    }

    @MainActor private func openServerDirect(_ server: WebServer) {
        guard let urlString = server.urlString,
              let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc @MainActor private func startServer(_ sender: NSMenuItem) {
        guard let server = sender.representedObject as? WebServer else { return }
        startServerDirect(server)
    }

    @MainActor private func startServerDirect(_ server: WebServer) {
        guard let cwd = server.cwd,
              let command = server.startCommand else { return }
        if startCommandRequiresConfirmation(command),
           !confirmShellStart(command: command, cwd: cwd) {
            return
        }
        registry.upsert(server)
        worker.async { [weak self] in
            launchServer(command: command, cwd: cwd, id: server.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                self?.refresh(updateOpenPopover: true)
            }
        }
    }

    @MainActor private func confirmShellStart(command: String, cwd: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Run stored start command?"
        alert.informativeText = """
        This command is not one of the generated safe start commands, so Codex Dashboard will run it through the shell in:
        \(abbreviatePath(cwd))

        \(command)
        """
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc @MainActor private func stopServer(_ sender: NSMenuItem) {
        guard let server = sender.representedObject as? WebServer else { return }
        stopServerDirect(server)
    }

    @MainActor private func stopServerDirect(_ server: WebServer) {
        guard let pid = server.pid else { return }
        registry.upsert(server)
        worker.async { [weak self] in
            _ = runCommand("/bin/kill", ["-TERM", String(pid)], timeout: 3)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self?.refresh(updateOpenPopover: true)
            }
        }
    }

    @objc @MainActor private func removeServer(_ sender: NSMenuItem) {
        guard let server = sender.representedObject as? WebServer else { return }
        removeServerDirect(server)
    }

    @MainActor private func removeServerDirect(_ server: WebServer) {
        registry.remove(id: server.id)
        refresh(updateOpenPopover: true)
    }

    @objc @MainActor private func openRegistry() {
        let path = homePath(".codex-menu-bar/servers.json")
        if !FileManager.default.fileExists(atPath: path) {
            ServerRegistry().save(ServerRegistryData())
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc @MainActor private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

func launchServer(command: String, cwd: String, id: String) {
    let logsDir = homePath(".codex-menu-bar/logs")
    ensureDirectory(logsDir)
    let safeID = id.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "|", with: "_")
    let logPath = "\(logsDir)/\(safeID).log"
    FileManager.default.createFile(atPath: logPath, contents: nil)
    guard let log = FileHandle(forWritingAtPath: logPath) else { return }
    _ = try? log.seekToEnd()

    let process = Process()
    if let spec = structuredStartCommand(command) {
        process.executableURL = URL(fileURLWithPath: spec.executable)
        process.arguments = spec.arguments
    } else {
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "exec \(command)"]
    }
    process.currentDirectoryURL = URL(fileURLWithPath: cwd)
    process.standardOutput = log
    process.standardError = log
    try? process.run()
}

func printSnapshotAndExit() -> Never {
    let snapshot = DashboardSnapshot(
        servers: ServerCollector().collect(),
        remoteConnections: RemoteProjectCollector().collect(),
        usage: CodexUsageCollector().collect(),
        caffeinateOn: CaffeinateController().isOn(),
        closedLidAwakeOn: ClosedLidAwakeController().isOn(),
        generatedAt: nowDate()
    )

    let formatter = ISO8601DateFormatter()
    func limitDictionary(_ limit: CodexLimit?) -> [String: Any]? {
        guard let limit else { return nil }
        return [
            "usedPercent": limit.usedPercent,
            "windowMinutes": limit.windowMinutes,
            "resetAt": formatter.string(from: limit.resetAt)
        ]
    }
    func jsonValue<T>(_ value: T?) -> Any {
        value ?? NSNull()
    }

    let payload: [String: Any] = [
        "generatedAt": formatter.string(from: snapshot.generatedAt),
        "caffeinateOn": snapshot.caffeinateOn,
        "closedLidAwakeOn": snapshot.closedLidAwakeOn,
        "usage": [
            "planType": jsonValue(snapshot.usage?.planType),
            "primary": jsonValue(limitDictionary(snapshot.usage?.primary)),
            "secondary": jsonValue(limitDictionary(snapshot.usage?.secondary)),
            "observedAt": jsonValue(snapshot.usage?.observedAt.map { formatter.string(from: $0) })
        ],
        "servers": snapshot.servers.map { server in
            [
                "id": server.id,
                "name": server.name,
                "port": jsonValue(server.port),
                "pid": jsonValue(server.pid),
                "cwd": jsonValue(server.cwd),
                "startCommand": jsonValue(server.startCommand),
                "running": server.isRunning,
                "url": jsonValue(server.urlString)
            ]
        },
        "remoteConnections": snapshot.remoteConnections.map { connection in
            [
                "hostId": connection.hostId,
                "displayName": connection.displayName,
                "alias": jsonValue(connection.alias),
                "hostname": jsonValue(connection.hostname),
                "sshUser": jsonValue(connection.sshUser),
                "sshPort": jsonValue(connection.sshPort),
                "projectCount": connection.projectCount,
                "autoConnect": connection.autoConnect,
                "selected": connection.isSelected,
                "tailscaleOnline": jsonValue(connection.tailscaleOnline),
                "tcpReachable": jsonValue(connection.tcpReachable),
                "sshAuthenticated": jsonValue(connection.sshAuthenticated),
                "remoteControlReachable": jsonValue(connection.remoteControlReachable),
                "status": connection.statusTitle,
                "detail": connection.detail,
                "authURL": jsonValue(connection.authURL)
            ]
        }
    ]

    if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
       let text = String(data: data, encoding: .utf8) {
        print(text)
    }
    exit(0)
}

if CommandLine.arguments.contains("--snapshot") {
    printSnapshotAndExit()
}

let app = NSApplication.shared
let delegate = DashboardController()
app.delegate = delegate
Task { @MainActor in
    delegate.start()
}
app.run()
