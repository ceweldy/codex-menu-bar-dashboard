import AppKit
import Darwin
import Foundation
@preconcurrency import UserNotifications
import UniformTypeIdentifiers

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
        remove(ids: [id])
    }

    func remove(ids: [String]) {
        let ids = Set(ids)
        guard !ids.isEmpty else { return }
        var registry = load()
        registry.servers.removeAll { ids.contains($0.id) }
        for id in ids where !registry.hiddenDiscoveredIDs.contains(id) {
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
    var cpuPercent: Double? = nil
    var memoryBytes: Int64? = nil
    var uptimeText: String? = nil
    var listenerCount: Int = 1
    var portConflict: Bool = false

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

struct ServerTerminationResult: Sendable {
    var stopped: Bool
    var forced: Bool
    var detail: String
}

private struct LocalProcessRecord {
    var pid: Int
    var parentPID: Int
    var command: String
}

private func localProcessTable() -> [Int: LocalProcessRecord] {
    let result = runCommand("/bin/ps", ["-axo", "pid=,ppid=,command="], timeout: 5)
    guard result.exitCode == 0 else { return [:] }

    var records: [Int: LocalProcessRecord] = [:]
    for line in result.stdout.split(separator: "\n") {
        let fields = line.split(maxSplits: 2, whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count == 3,
              let pid = Int(fields[0]),
              let parentPID = Int(fields[1]) else { continue }
        records[pid] = LocalProcessRecord(pid: pid, parentPID: parentPID, command: String(fields[2]))
    }
    return records
}

private func localProcessExists(_ pid: Int) -> Bool {
    guard pid > 0 else { return false }
    if Darwin.kill(pid_t(pid), 0) == 0 { return true }
    return errno == EPERM
}

private func currentWorkingDirectoryForProcess(_ pid: Int) -> String? {
    let result = runCommand("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"], timeout: 3)
    guard result.exitCode == 0 else { return nil }
    for line in result.stdout.split(separator: "\n") where line.hasPrefix("n") {
        let path = String(line.dropFirst())
        if !path.isEmpty { return path }
    }
    return nil
}

private func listenerPIDs(on port: Int) -> Set<Int> {
    let result = runCommand(
        "/usr/sbin/lsof",
        ["-nP", "-t", "-iTCP:\(port)", "-sTCP:LISTEN"],
        timeout: 4
    )
    guard result.exitCode == 0 else { return [] }
    return Set(result.stdout.split(whereSeparator: { $0 == "\n" || $0 == " " || $0 == "\t" }).compactMap { Int($0) })
}

private func standardizedLocalPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
}

private func path(_ candidate: String, isInside root: String) -> Bool {
    let candidate = standardizedLocalPath(candidate)
    let root = standardizedLocalPath(root)
    return candidate == root || candidate.hasPrefix(root + "/")
}

private func processBelongsToServer(_ pid: Int, server: WebServer) -> Bool {
    if pid == server.pid { return true }
    guard let root = server.cwd,
          let cwd = currentWorkingDirectoryForProcess(pid) else { return false }
    return path(cwd, isInside: root)
}

private func commandLooksLikeServerLauncher(_ command: String) -> Bool {
    let lower = command.lowercased()
    let hints = [
        "npm ", "npm-cli", "pnpm", "yarn", "bun ", "npx ",
        "node ", "vite", "next", "astro", "nuxt", "svelte", "remix",
        "deno", "uvicorn", "gunicorn", "flask", "manage.py", "rails",
        "python -m http.server", "python3 -m http.server"
    ]
    return hints.contains { lower.contains($0) }
}

private func matchingServerListenerPIDs(_ server: WebServer) -> Set<Int> {
    guard let port = server.port else {
        if let pid = server.pid, localProcessExists(pid) { return [pid] }
        return []
    }
    return Set(listenerPIDs(on: port).filter { processBelongsToServer($0, server: server) })
}

private func serverTerminationTargets(_ server: WebServer) -> Set<Int> {
    let table = localProcessTable()
    var seeds = matchingServerListenerPIDs(server)
    if let pid = server.pid, localProcessExists(pid) {
        seeds.insert(pid)
    }

    // Include a recognizable package-manager/server parent in the same project.
    // This prevents npm/pnpm wrappers from immediately respawning a killed child,
    // without ever walking up into Terminal, Codex, or another unrelated shell.
    var roots = seeds
    for seed in seeds {
        var nextParent = table[seed]?.parentPID
        while let parentPID = nextParent,
              parentPID > 1,
              let parent = table[parentPID],
              commandLooksLikeServerLauncher(parent.command),
              processBelongsToServer(parentPID, server: server) {
            roots.insert(parentPID)
            nextParent = table[parentPID]?.parentPID
        }
    }

    var children: [Int: [Int]] = [:]
    for record in table.values {
        children[record.parentPID, default: []].append(record.pid)
    }

    var targets = roots
    var pending = Array(roots)
    while let pid = pending.popLast() {
        for child in children[pid, default: []] where !targets.contains(child) {
            targets.insert(child)
            pending.append(child)
        }
    }
    return Set(targets.filter(localProcessExists))
}

private func sendSignal(_ signal: Int32, to pids: Set<Int>) {
    // Children first gives package-manager wrappers a chance to exit cleanly.
    for pid in pids.sorted(by: >) {
        _ = Darwin.kill(pid_t(pid), signal)
    }
}

private func waitForServerToStop(_ server: WebServer, knownTargets: Set<Int>, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        let listenerGone = matchingServerListenerPIDs(server).isEmpty
        let processesGone = !knownTargets.contains(where: localProcessExists)
        if listenerGone && processesGone { return true }
        Thread.sleep(forTimeInterval: 0.1)
    } while Date() < deadline
    return matchingServerListenerPIDs(server).isEmpty
}

func terminateWebServer(_ server: WebServer) -> ServerTerminationResult {
    var targets = serverTerminationTargets(server)
    if targets.isEmpty && matchingServerListenerPIDs(server).isEmpty {
        return ServerTerminationResult(stopped: true, forced: false, detail: "Already stopped")
    }

    sendSignal(SIGTERM, to: targets)
    if waitForServerToStop(server, knownTargets: targets, timeout: 2.0) {
        return ServerTerminationResult(stopped: true, forced: false, detail: "Stopped")
    }

    // Resolve again before forcing so a wrapper cannot leave behind or respawn a
    // listener under a new PID while the button appears to do nothing.
    for _ in 0..<2 {
        targets.formUnion(serverTerminationTargets(server))
        sendSignal(SIGKILL, to: targets)
        if waitForServerToStop(server, knownTargets: targets, timeout: 1.0) {
            return ServerTerminationResult(stopped: true, forced: true, detail: "Stopped (forced)")
        }
    }

    let portDescription = server.port.map { " on port \($0)" } ?? ""
    return ServerTerminationResult(
        stopped: false,
        forced: true,
        detail: "Could not stop the listener\(portDescription). Try again."
    )
}

struct LsofEndpoint {
    var pid: Int
    var commandName: String
    var port: Int
}

final class ServerCollector: @unchecked Sendable {
    private let registry = ServerRegistry()
    private let config: AppConfig

    init(config: AppConfig = .load()) {
        self.config = config
    }

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

        for service in config.localServices {
            if var existing = byID[service.id] {
                existing.name = service.name
                existing.cwd = service.cwd
                existing.startCommand = service.startCommand
                byID[service.id] = existing
            } else {
                byID[service.id] = WebServer(
                    id: service.id,
                    name: service.name,
                    port: service.port,
                    pid: nil,
                    command: service.startCommand,
                    cwd: service.cwd,
                    startCommand: service.startCommand,
                    isRunning: false,
                    listenerCount: 0
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
            let telemetry = processTelemetry(pid: endpoint.pid)
            let listenersOnPort = Set(endpoints.filter { $0.port == endpoint.port }.map(\.pid))

            servers.append(WebServer(
                id: id,
                name: name,
                port: endpoint.port,
                pid: endpoint.pid,
                command: command,
                cwd: root,
                startCommand: startCommand,
                isRunning: true,
                cpuPercent: telemetry.cpuPercent,
                memoryBytes: telemetry.memoryBytes,
                uptimeText: telemetry.uptimeText,
                listenerCount: listenersOnPort.count,
                portConflict: listenersOnPort.count > 1
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

    private func processTelemetry(pid: Int) -> (cpuPercent: Double?, memoryBytes: Int64?, uptimeText: String?) {
        let output = runCommand(
            "/bin/ps",
            ["-p", String(pid), "-o", "%cpu=,rss=,etime="],
            timeout: 3
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = output.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard fields.count >= 3 else { return (nil, nil, nil) }
        let cpu = Double(fields[0])
        let memory = Int64(fields[1]).map { $0 * 1024 }
        return (cpu, memory, fields[2])
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

struct BrandingConfig: Codable, Hashable {
    var name: String
    var subtitle: String
    var iconPath: String?

    enum CodingKeys: String, CodingKey {
        case name
        case subtitle
        case iconPath
    }

    init(name: String = "CODEX DASHBOARD", subtitle: String = "Control Center", iconPath: String? = nil) {
        self.name = name
        self.subtitle = subtitle
        self.iconPath = iconPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "CODEX DASHBOARD"
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle) ?? "Control Center"
        iconPath = try container.decodeIfPresent(String.self, forKey: .iconPath)
    }
}

struct WatchdogPolicyConfig: Codable, Hashable {
    var enabled: Bool
    var autoRestart: Bool
    var notifications: Bool

    init(enabled: Bool = false, autoRestart: Bool = false, notifications: Bool = false) {
        self.enabled = enabled
        self.autoRestart = autoRestart
        self.notifications = notifications
    }
}

struct LocalServiceConfig: Codable, Hashable {
    var id: String
    var name: String
    var cwd: String
    var startCommand: String
    var port: Int
    var watchdog: WatchdogPolicyConfig
}

struct RemoteServiceConfig: Codable, Hashable {
    var id: String
    var name: String
    var target: String
    var launchAgentLabel: String
    var launchAgentPlist: String
    var port: Int
    var healthURL: String?
    var logPaths: [String]
    var watchdog: WatchdogPolicyConfig
}

struct ProjectStackConfig: Codable, Hashable {
    var id: String
    var name: String
    var localServiceIDs: [String]
    var remoteServiceIDs: [String]
}

struct PublishTargetConfig: Codable, Hashable {
    var id: String
    var name: String
    var localServiceID: String
    var port: Int
}

struct AppConfig: Codable {
    var branding: BrandingConfig = BrandingConfig()
    var remoteHelpers: [RemoteHelperConfig] = []
    var localServices: [LocalServiceConfig] = []
    var remoteServices: [RemoteServiceConfig] = []
    var projectStacks: [ProjectStackConfig] = []
    var publishTargets: [PublishTargetConfig] = []

    enum CodingKeys: String, CodingKey {
        case branding
        case remoteHelpers
        case localServices
        case remoteServices
        case projectStacks
        case publishTargets
    }

    init(
        branding: BrandingConfig = BrandingConfig(),
        remoteHelpers: [RemoteHelperConfig] = [],
        localServices: [LocalServiceConfig] = [],
        remoteServices: [RemoteServiceConfig] = [],
        projectStacks: [ProjectStackConfig] = [],
        publishTargets: [PublishTargetConfig] = []
    ) {
        self.branding = branding
        self.remoteHelpers = remoteHelpers
        self.localServices = localServices
        self.remoteServices = remoteServices
        self.projectStacks = projectStacks
        self.publishTargets = publishTargets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        branding = try container.decodeIfPresent(BrandingConfig.self, forKey: .branding) ?? BrandingConfig()
        remoteHelpers = try container.decodeIfPresent([RemoteHelperConfig].self, forKey: .remoteHelpers) ?? []
        localServices = try container.decodeIfPresent([LocalServiceConfig].self, forKey: .localServices) ?? []
        remoteServices = try container.decodeIfPresent([RemoteServiceConfig].self, forKey: .remoteServices) ?? []
        projectStacks = try container.decodeIfPresent([ProjectStackConfig].self, forKey: .projectStacks) ?? []
        publishTargets = try container.decodeIfPresent([PublishTargetConfig].self, forKey: .publishTargets) ?? []
    }

    static var filePath: String {
        let environment = ProcessInfo.processInfo.environment
        return environment["CODEX_MENU_BAR_CONFIG"].map(expandedHomePath)
            ?? homePath(".codex-menu-bar/config.json")
    }

    static func load() -> AppConfig {
        let path = filePath
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

    func save() {
        ensureDirectory(URL(fileURLWithPath: Self.filePath).deletingLastPathComponent().path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: URL(fileURLWithPath: Self.filePath), options: .atomic)
    }
}

enum ActivityLevel: String, Codable, Hashable {
    case info
    case success
    case warning
    case error
}

struct ActivityEvent: Codable, Hashable, Identifiable {
    var id: UUID
    var date: Date
    var category: String
    var title: String
    var detail: String
    var level: ActivityLevel
}

final class ActivityStore: @unchecked Sendable {
    private let lock = NSLock()
    private let filePath = homePath(".codex-menu-bar/activity.json")
    private let maximumEvents = 200

    var path: String { filePath }

    func load(limit: Int = 30) -> [ActivityEvent] {
        lock.lock(); defer { lock.unlock() }
        return Array(loadUnlocked().prefix(max(0, limit)))
    }

    @discardableResult
    func record(category: String, title: String, detail: String, level: ActivityLevel = .info) -> ActivityEvent {
        lock.lock(); defer { lock.unlock() }
        let event = ActivityEvent(id: UUID(), date: Date(), category: category, title: title, detail: detail, level: level)
        var events = loadUnlocked()
        events.insert(event, at: 0)
        saveUnlocked(Array(events.prefix(maximumEvents)))
        return event
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        saveUnlocked([])
    }

    private func loadUnlocked() -> [ActivityEvent] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ActivityEvent].self, from: data)) ?? []
    }

    private func saveUnlocked(_ events: [ActivityEvent]) {
        ensureDirectory(URL(fileURLWithPath: filePath).deletingLastPathComponent().path)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(events) else { return }
        try? data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
    }
}

final class NotificationController: @unchecked Sendable {
    func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                self.deliver(center: center, title: title, body: body)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted {
                        self.deliver(center: center, title: title, body: body)
                    }
                }
            default:
                break
            }
        }
    }

    private func deliver(center: UNUserNotificationCenter, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request)
    }
}

struct RemoteServiceStatus: Hashable {
    var config: RemoteServiceConfig
    var loaded: Bool
    var running: Bool
    var pid: Int?
    var healthOK: Bool?
    var cpuPercent: Double?
    var memoryBytes: Int64?
    var uptimeText: String?
    var detail: String
    var observedAt: Date
}

struct RemoteServiceActionResult: Sendable {
    var succeeded: Bool
    var detail: String
}

enum RemoteServiceCommand: Equatable {
    case start
    case stop
    case restart
}

final class RemoteServiceController: @unchecked Sendable {
    private let services: [RemoteServiceConfig]

    init(config: AppConfig) {
        services = config.remoteServices
    }

    func collect() -> [RemoteServiceStatus] {
        services.map(status).sorted { $0.config.name.localizedCaseInsensitiveCompare($1.config.name) == .orderedAscending }
    }

    func start(_ service: RemoteServiceConfig) -> RemoteServiceActionResult {
        let label = shellQuoted(service.launchAgentLabel)
        let plist = shellQuoted(service.launchAgentPlist)
        let script = "uid=$(/usr/bin/id -u); /bin/launchctl print gui/$uid/\(label) >/dev/null 2>&1 || /bin/launchctl bootstrap gui/$uid \(plist); /bin/launchctl kickstart -k gui/$uid/\(label)"
        return action(service, script: script, success: "Started \(service.name) on \(service.target)")
    }

    func stop(_ service: RemoteServiceConfig) -> RemoteServiceActionResult {
        let label = shellQuoted(service.launchAgentLabel)
        let script = "uid=$(/usr/bin/id -u); /bin/launchctl bootout gui/$uid/\(label)"
        let result = ssh(service, script: script, timeout: 12)
        if result.exitCode == 0 || result.stderr.contains("Could not find service") {
            return RemoteServiceActionResult(succeeded: true, detail: "Stopped \(service.name) on \(service.target)")
        }
        return RemoteServiceActionResult(succeeded: false, detail: cleanRemoteError(result))
    }

    func restart(_ service: RemoteServiceConfig) -> RemoteServiceActionResult {
        let startResult = start(service)
        return RemoteServiceActionResult(
            succeeded: startResult.succeeded,
            detail: startResult.succeeded ? "Restarted \(service.name) on \(service.target)" : startResult.detail
        )
    }

    func fetchLogs(_ service: RemoteServiceConfig, lines: Int = 120) -> RemoteServiceActionResult {
        guard !service.logPaths.isEmpty else {
            return RemoteServiceActionResult(succeeded: false, detail: "No remote log paths are configured")
        }
        let commands = service.logPaths.map { path in
            "echo '===== \(path.replacingOccurrences(of: "'", with: "")) ====='; /usr/bin/tail -n \(max(1, min(lines, 500))) \(shellQuoted(path)) 2>&1"
        }
        let result = ssh(service, script: commands.joined(separator: "; "), timeout: 12)
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0 || !output.isEmpty else {
            return RemoteServiceActionResult(succeeded: false, detail: cleanRemoteError(result))
        }
        return RemoteServiceActionResult(succeeded: true, detail: output)
    }

    private func status(_ service: RemoteServiceConfig) -> RemoteServiceStatus {
        let label = shellQuoted(service.launchAgentLabel)
        let healthCommand: String
        if let healthURL = service.healthURL {
            healthCommand = "http_code=$(/usr/bin/curl -sS --max-time 4 -o /dev/null -w '%{http_code}' \(shellQuoted(healthURL)) 2>/dev/null || true); echo __HTTP__=$http_code"
        } else {
            healthCommand = "echo __HTTP__="
        }
        let script = "uid=$(/usr/bin/id -u); if /bin/launchctl print gui/$uid/\(label) >/dev/null 2>&1; then echo __LOADED__=1; else echo __LOADED__=0; fi; pid=$(/usr/sbin/lsof -nP -t -iTCP:\(service.port) -sTCP:LISTEN 2>/dev/null | /usr/bin/head -1); echo __PID__=$pid; if [ -n \"$pid\" ]; then metrics=$(/bin/ps -p $pid -o %cpu=,rss=,etime= | /usr/bin/xargs); echo __PS__=$metrics; fi; \(healthCommand)"
        let result = ssh(service, script: script, timeout: 14)
        let loaded = marker("__LOADED__", in: result.stdout) == "1"
        let pid = marker("__PID__", in: result.stdout).flatMap(Int.init)
        let httpCode = marker("__HTTP__", in: result.stdout).flatMap(Int.init)
        let fields = marker("__PS__", in: result.stdout)?.split(separator: " ").map(String.init) ?? []
        let cpu = fields.first.flatMap(Double.init)
        let memory = fields.count > 1 ? Int64(fields[1]).map { $0 * 1024 } : nil
        let uptime = fields.count > 2 ? fields[2] : nil
        let healthOK = httpCode.map { (200..<400).contains($0) }
        let running = pid != nil
        let detail: String
        if result.exitCode != 0 {
            detail = cleanRemoteError(result)
        } else if running && healthOK != false {
            detail = healthOK == true ? "Running and healthy" : "Running; no health check configured"
        } else if running {
            detail = "Process is running, but the health check failed"
        } else if loaded {
            detail = "LaunchAgent is loaded, but no listener is active on port \(service.port)"
        } else {
            detail = "Stopped"
        }
        return RemoteServiceStatus(
            config: service,
            loaded: loaded,
            running: running,
            pid: pid,
            healthOK: healthOK,
            cpuPercent: cpu,
            memoryBytes: memory,
            uptimeText: uptime,
            detail: detail,
            observedAt: Date()
        )
    }

    private func action(_ service: RemoteServiceConfig, script: String, success: String) -> RemoteServiceActionResult {
        let result = ssh(service, script: script, timeout: 15)
        if result.exitCode == 0 {
            return RemoteServiceActionResult(succeeded: true, detail: success)
        }
        return RemoteServiceActionResult(succeeded: false, detail: cleanRemoteError(result))
    }

    private func ssh(_ service: RemoteServiceConfig, script: String, timeout: TimeInterval) -> CommandResult {
        runCommand(
            "/usr/bin/ssh",
            ["-o", "BatchMode=yes", "-o", "NumberOfPasswordPrompts=0", "-o", "ConnectTimeout=6", service.target, script],
            timeout: timeout
        )
    }

    private func marker(_ name: String, in output: String) -> String? {
        output.components(separatedBy: .newlines)
            .first { $0.hasPrefix(name + "=") }
            .map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func cleanRemoteError(_ result: CommandResult) -> String {
        let text = (result.stderr + "\n" + result.stdout)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(2)
            .joined(separator: " ")
        return text.isEmpty ? "Remote command failed (exit \(result.exitCode))" : text
    }
}

enum PublishMode: String, Codable, Hashable {
    case off
    case tailnet
    case funnel
}

struct PublishStatus: Hashable {
    var config: PublishTargetConfig
    var mode: PublishMode
    var url: String?
    var detail: String
}

final class TailscalePublishController: @unchecked Sendable {
    private let targets: [PublishTargetConfig]

    init(config: AppConfig) {
        targets = config.publishTargets
    }

    func collect() -> [PublishStatus] {
        guard let executable = executable() else {
            return targets.map { PublishStatus(config: $0, mode: .off, url: nil, detail: "Tailscale CLI is unavailable") }
        }
        let serve = runCommand(executable, ["serve", "status", "--json"], timeout: 6).stdout
        let funnel = runCommand(executable, ["funnel", "status", "--json"], timeout: 6).stdout
        return targets.map { target in
            let portNeedle = ":\(target.port)"
            if funnel.contains(portNeedle) {
                return PublishStatus(config: target, mode: .funnel, url: firstHTTPSURL(in: funnel), detail: "Public internet via Tailscale Funnel")
            }
            if serve.contains(portNeedle) {
                return PublishStatus(config: target, mode: .tailnet, url: firstHTTPSURL(in: serve), detail: "Private to your Tailscale network")
            }
            return PublishStatus(config: target, mode: .off, url: nil, detail: "Not shared")
        }
    }

    func setMode(_ mode: PublishMode, target: PublishTargetConfig) -> RemoteServiceActionResult {
        guard let executable = executable() else {
            return RemoteServiceActionResult(succeeded: false, detail: "Tailscale CLI is unavailable")
        }
        let disableServe = runCommand(executable, ["serve", "--https=443", "off"], timeout: 10)
        let disableFunnel = runCommand(executable, ["funnel", "--https=443", "off"], timeout: 10)
        if mode == .off {
            let ok = disableServe.exitCode == 0 || disableFunnel.exitCode == 0
            return RemoteServiceActionResult(succeeded: ok, detail: ok ? "Sharing disabled" : "No active share was found")
        }
        let command = mode == .tailnet ? "serve" : "funnel"
        let result = runCommand(
            executable,
            [command, "--bg", "--yes", "http://127.0.0.1:\(target.port)"],
            timeout: 20
        )
        if result.exitCode == 0 {
            let scope = mode == .tailnet ? "your tailnet" : "the public internet"
            return RemoteServiceActionResult(succeeded: true, detail: "Shared \(target.name) with \(scope)")
        }
        let detail = (result.stderr + "\n" + result.stdout)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return RemoteServiceActionResult(succeeded: false, detail: detail.isEmpty ? "Tailscale command failed" : detail)
    }

    private func executable() -> String? {
        let appPath = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        if FileManager.default.isExecutableFile(atPath: appPath) { return appPath }
        let result = runCommand("/usr/bin/which", ["tailscale"], timeout: 2)
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.exitCode == 0 && !path.isEmpty ? path : nil
    }

    private func firstHTTPSURL(in text: String) -> String? {
        guard let range = text.range(of: #"https://[^\s\"\\]+"#, options: .regularExpression) else { return nil }
        return String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,}"))
    }
}

func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
    private let sshProbeCacheLock = NSLock()
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
        if !force {
            sshProbeCacheLock.lock()
            let cached = sshProbeCache[target]
            sshProbeCacheLock.unlock()
            if let cached,
               Date().timeIntervalSince(cached.observedAt) < sshProbeCacheSeconds {
                return cached.result
            }
        }
        let result = sshAuthProbe(target: target)
        sshProbeCacheLock.lock()
        sshProbeCache[target] = (Date(), result)
        sshProbeCacheLock.unlock()
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
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(),
              ["127.0.0.1", "localhost", "::1"].contains(host) else {
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
    var remoteServices: [RemoteServiceStatus]
    var publishStatuses: [PublishStatus]
    var activityEvents: [ActivityEvent]
    var usage: CodexUsage?
    var caffeinateOn: Bool
    var closedLidAwakeOn: Bool
    var generatedAt: Date

    static let empty = DashboardSnapshot(
        servers: [],
        remoteConnections: [],
        remoteServices: [],
        publishStatuses: [],
        activityEvents: [],
        usage: nil,
        caffeinateOn: false,
        closedLidAwakeOn: false,
        generatedAt: .distantPast
    )
}

final class DashboardRefreshAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var servers: [WebServer] = []
    private var remoteConnections: [RemoteConnectionStatus] = []
    private var remoteServices: [RemoteServiceStatus] = []
    private var publishStatuses: [PublishStatus] = []
    private var activityEvents: [ActivityEvent] = []
    private var usage: CodexUsage?
    private var caffeinateOn = false
    private var closedLidAwakeOn = false

    func setServers(_ value: [WebServer]) {
        lock.lock(); defer { lock.unlock() }
        servers = value
    }

    func setRemoteConnections(_ value: [RemoteConnectionStatus]) {
        lock.lock(); defer { lock.unlock() }
        remoteConnections = value
    }

    func setRemoteServices(_ value: [RemoteServiceStatus]) {
        lock.lock(); defer { lock.unlock() }
        remoteServices = value
    }

    func setPublishStatuses(_ value: [PublishStatus]) {
        lock.lock(); defer { lock.unlock() }
        publishStatuses = value
    }

    func setActivityEvents(_ value: [ActivityEvent]) {
        lock.lock(); defer { lock.unlock() }
        activityEvents = value
    }

    func setUsage(_ value: CodexUsage?) {
        lock.lock(); defer { lock.unlock() }
        usage = value
    }

    func setCaffeinateOn(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        caffeinateOn = value
    }

    func setClosedLidAwakeOn(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        closedLidAwakeOn = value
    }

    func snapshot(generatedAt: Date) -> DashboardSnapshot {
        lock.lock(); defer { lock.unlock() }
        return DashboardSnapshot(
            servers: servers,
            remoteConnections: remoteConnections,
            remoteServices: remoteServices,
            publishStatuses: publishStatuses,
            activityEvents: activityEvents,
            usage: usage,
            caffeinateOn: caffeinateOn,
            closedLidAwakeOn: closedLidAwakeOn,
            generatedAt: generatedAt
        )
    }
}

final class ActionButton: NSButton {
    var handler: (() -> Void)?

    convenience init(title: String, symbolName: String? = nil, handler: @escaping () -> Void) {
        self.init(title: title, target: nil, action: nil)
        self.handler = handler
        self.target = self
        self.action = #selector(runHandler)
        self.bezelStyle = .rounded
        self.controlSize = .small
        self.font = NSFont.systemFont(ofSize: 12)
        if let symbolName,
           let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title) {
            image.isTemplate = true
            self.image = image
            self.imagePosition = .imageLeading
            self.imageHugsTitle = true
        }
    }

    @objc private func runHandler() {
        handler?()
    }
}

final class StatusPill: NSView {
    convenience init(text: String, symbolName: String, color: NSColor) {
        self.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = color.withAlphaComponent(0.13).cgColor

        let imageView = NSImageView()
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: text) {
            image.isTemplate = true
            imageView.image = image
        }
        imageView.contentTintColor = color
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)

        let textField = NSTextField(labelWithString: text)
        textField.font = .systemFont(ofSize: 10.5, weight: .semibold)
        textField.textColor = color
        textField.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [imageView, textField])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 20)
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let configPath: String
    private let onSave: (BrandingConfig) -> Void
    private let onClose: () -> Void
    private let nameField: NSTextField
    private let subtitleField: NSTextField
    private let iconField: NSTextField

    init(
        branding: BrandingConfig,
        configPath: String,
        onSave: @escaping (BrandingConfig) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.configPath = configPath
        self.onSave = onSave
        self.onClose = onClose
        nameField = NSTextField(string: branding.name)
        subtitleField = NSTextField(string: branding.subtitle)
        iconField = NSTextField(string: branding.iconPath ?? "")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 390),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Dashboard Settings"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        configureContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
        window?.makeKeyAndOrderFront(sender)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }

    private func configureContent() {
        guard let contentView = window?.contentView else { return }
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20)
        ])

        let title = NSTextField(labelWithString: "Appearance")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        root.addArrangedSubview(title)

        let description = NSTextField(wrappingLabelWithString: "Customize the dashboard labels or choose another transparent menu-bar template image. These values stay in your local configuration file.")
        description.font = .systemFont(ofSize: 11.5)
        description.textColor = .secondaryLabelColor
        description.maximumNumberOfLines = 2
        description.widthAnchor.constraint(equalToConstant: 512).isActive = true
        root.addArrangedSubview(description)

        nameField.placeholderString = "CODEX DASHBOARD"
        subtitleField.placeholderString = "Control Center"
        iconField.placeholderString = "Bundled logo"
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        iconField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let chooseIcon = NSButton(title: "Choose…", target: self, action: #selector(chooseIconFile))
        chooseIcon.bezelStyle = .rounded
        let bundledIcon = NSButton(title: "Use Bundled", target: self, action: #selector(useBundledIcon))
        bundledIcon.bezelStyle = .rounded
        let iconControls = NSStackView(views: [iconField, chooseIcon, bundledIcon])
        iconControls.orientation = .horizontal
        iconControls.alignment = .centerY
        iconControls.spacing = 7
        iconField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        let grid = NSGridView(views: [
            [settingsLabel("Name"), nameField],
            [settingsLabel("Subtitle"), subtitleField],
            [settingsLabel("Menu Bar Icon"), iconControls]
        ])
        grid.rowSpacing = 11
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.widthAnchor.constraint(equalToConstant: 512).isActive = true
        root.addArrangedSubview(grid)

        let separator = NSBox()
        separator.boxType = .separator
        separator.widthAnchor.constraint(equalToConstant: 512).isActive = true
        root.addArrangedSubview(separator)

        let filesTitle = NSTextField(labelWithString: "Dashboard Data")
        filesTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        root.addArrangedSubview(filesTitle)

        let configLocation = NSTextField(labelWithString: abbreviatePath(configPath))
        configLocation.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        configLocation.textColor = .secondaryLabelColor
        configLocation.lineBreakMode = .byTruncatingMiddle
        configLocation.widthAnchor.constraint(equalToConstant: 512).isActive = true
        root.addArrangedSubview(configLocation)

        let configButton = NSButton(title: "Open Configuration", target: self, action: #selector(openConfigurationFile))
        let registryButton = NSButton(title: "Open Server Registry", target: self, action: #selector(openServerRegistry))
        let activityButton = NSButton(title: "Open Activity History", target: self, action: #selector(openActivityHistory))
        for button in [configButton, registryButton, activityButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
        }
        let fileButtons = NSStackView(views: [configButton, registryButton, activityButton])
        fileButtons.orientation = .horizontal
        fileButtons.spacing = 7
        root.addArrangedSubview(fileButtons)

        let flexibleSpace = NSView()
        flexibleSpace.setContentHuggingPriority(.defaultLow, for: .vertical)
        root.addArrangedSubview(flexibleSpace)

        let restore = NSButton(title: "Restore Generic Defaults", target: self, action: #selector(restoreDefaults))
        restore.bezelStyle = .rounded
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelSettings))
        cancel.bezelStyle = .rounded
        let save = NSButton(title: "Save", target: self, action: #selector(saveSettings))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        let buttonSpacer = NSView()
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [restore, buttonSpacer, cancel, save])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8
        actions.widthAnchor.constraint(equalToConstant: 512).isActive = true
        root.addArrangedSubview(actions)
    }

    private func settingsLabel(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12, weight: .medium)
        field.alignment = .right
        return field
    }

    @objc private func chooseIconFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose Menu Bar Icon"
        panel.prompt = "Choose"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        if panel.runModal() == .OK, let url = panel.url {
            iconField.stringValue = abbreviatePath(url.path)
        }
    }

    @objc private func useBundledIcon() {
        iconField.stringValue = ""
    }

    @objc private func restoreDefaults() {
        nameField.stringValue = "CODEX DASHBOARD"
        subtitleField.stringValue = "Control Center"
        iconField.stringValue = ""
    }

    @objc private func cancelSettings() {
        window?.close()
    }

    @objc private func saveSettings() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitle = subtitleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let iconPath = iconField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(BrandingConfig(
            name: name.isEmpty ? "CODEX DASHBOARD" : name,
            subtitle: subtitle.isEmpty ? "Control Center" : subtitle,
            iconPath: iconPath.isEmpty ? nil : iconPath
        ))
        window?.close()
    }

    @objc private func openConfigurationFile() {
        if !FileManager.default.fileExists(atPath: configPath) {
            AppConfig().save()
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: configPath))
    }

    @objc private func openServerRegistry() {
        let path = homePath(".codex-menu-bar/servers.json")
        if !FileManager.default.fileExists(atPath: path) {
            ServerRegistry().save(ServerRegistryData())
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func openActivityHistory() {
        let store = ActivityStore()
        if !FileManager.default.fileExists(atPath: store.path) {
            store.clear()
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: store.path))
    }
}

final class DashboardController: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private static let refreshInterval: TimeInterval = 60
    private static let localRefreshInterval: TimeInterval = 5
    private static let dashboardWidth: CGFloat = 400
    private static let cardWidth: CGFloat = 368
    private let openMenuOnLaunch = CommandLine.arguments.contains("--open-menu-on-launch")
    private let openSettingsOnLaunch = CommandLine.arguments.contains("--open-settings-on-launch")
    private var statusItem: NSStatusItem?
    private var currentMenu: NSMenu?
    private var popover: NSPopover?
    private var settingsWindowController: SettingsWindowController?
    private let worker = DispatchQueue(label: "codex-menu-bar.worker", qos: .userInitiated)
    private let refreshWorker = DispatchQueue(label: "codex-menu-bar.refresh", qos: .userInitiated, attributes: .concurrent)
    private let serverWorker = DispatchQueue(label: "codex-menu-bar.server-actions", qos: .userInitiated, attributes: .concurrent)
    private let operationsWorker = DispatchQueue(label: "codex-menu-bar.operations", qos: .userInitiated, attributes: .concurrent)
    private let caffeinateWorker = DispatchQueue(label: "codex-menu-bar.caffeinate", qos: .userInitiated)
    private let closedLidWorker = DispatchQueue(label: "codex-menu-bar.closed-lid", qos: .userInitiated)
    private var config = AppConfig.load()
    private lazy var serverCollector = ServerCollector(config: config)
    private lazy var remoteProjectCollector = RemoteProjectCollector(config: config)
    private lazy var remoteServiceController = RemoteServiceController(config: config)
    private lazy var publishController = TailscalePublishController(config: config)
    private let usageCollector = CodexUsageCollector()
    private let caffeinate = CaffeinateController()
    private let closedLidAwake = ClosedLidAwakeController()
    private let registry = ServerRegistry()
    private let activityStore = ActivityStore()
    private let notificationController = NotificationController()
    private var snapshot = DashboardSnapshot.empty
    private var timer: Timer?
    private var localTimer: Timer?
    private var watchdogTimer: Timer?
    private var isRefreshing = false
    private var isLocalRefreshing = false
    private var refreshRequestedWhileRefreshing = false
    private var pendingPopoverUpdateAfterRefresh = false
    private var lastFullRefreshAt = Date.distantPast
    private var lastRefreshDuration: TimeInterval?
    private var serverActionsInProgress: [String: String] = [:]
    private var serverActionMessages: [String: String] = [:]
    private var remoteServiceActionsInProgress: [String: String] = [:]
    private var remoteServiceActionMessages: [String: String] = [:]
    private var publishActionsInProgress: Set<String> = []
    private var publishActionMessages: [String: String] = [:]
    private var stackActionsInProgress: Set<String> = []
    private var watchdogLastHealthy: [String: Bool] = [:]
    private var watchdogLastRestartAt: [String: Date] = [:]
    private var watchdogSuppressedIDs: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "suppressedWatchdogs") ?? [])
    private var collapsedSectionIDs: Set<String> = {
        if let saved = UserDefaults.standard.array(forKey: "collapsedDashboardSections") as? [String] {
            return Set(saved)
        }
        return ["activity", "usage", "connections"]
    }()
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
        // If the user opens the popover while the initial collection is still
        // running, replace the placeholder content as soon as real data arrives.
        refresh(updateOpenPopover: true)
        timer = Timer.scheduledTimer(timeInterval: Self.refreshInterval, target: self, selector: #selector(refreshNow), userInfo: nil, repeats: true)
        localTimer = Timer.scheduledTimer(timeInterval: Self.localRefreshInterval, target: self, selector: #selector(refreshLocalStateIfPopoverOpen), userInfo: nil, repeats: true)
        watchdogTimer = Timer.scheduledTimer(timeInterval: 20, target: self, selector: #selector(runWatchdogCheck), userInfo: nil, repeats: true)
        if openMenuOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                runtimeLog("openMenuOnLaunch buttonExists=\(self?.statusItem?.button != nil)")
                self?.showDashboardPopover()
            }
        }
        if openSettingsOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.openSettingsDirect()
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
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "\(brandingName) menu bar dashboard"
        button.setAccessibilityLabel("\(brandingName) menu bar dashboard")
        if let image = configuredStatusImage() {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.title = ""
        } else if let image = NSImage(systemSymbolName: "bolt.horizontal.circle.fill", accessibilityDescription: "Custom Codex Dashboard") {
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

    private var brandingName: String {
        let value = config.branding.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "CODEX DASHBOARD" : value
    }

    private var brandingSubtitle: String {
        let value = config.branding.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Control Center" : value
    }

    private func configuredStatusImage() -> NSImage? {
        let configuredURL = config.branding.iconPath
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: expandedHomePath($0)) }
        let bundledURL = Bundle.main.url(forResource: "menu-bar-template", withExtension: "png")
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/menu-bar-template.png")

        for url in [configuredURL, bundledURL, sourceURL].compactMap({ $0 }) {
            if let image = NSImage(contentsOf: url) {
                return image
            }
        }
        return nil
    }

    @MainActor private func refresh(updateOpenPopover: Bool = false) {
        if updateOpenPopover {
            pendingPopoverUpdateAfterRefresh = true
        }
        guard !isRefreshing else {
            refreshRequestedWhileRefreshing = true
            return
        }
        isRefreshing = true
        let refreshStartedAt = Date()
        if popover?.isShown == true {
            refreshPopoverContentIfShown()
        }
        let serverCollector = serverCollector
        let remoteProjectCollector = remoteProjectCollector
        let remoteServiceController = remoteServiceController
        let publishController = publishController
        let activityStore = activityStore
        let usageCollector = usageCollector
        let caffeinate = caffeinate
        let closedLidAwake = closedLidAwake
        let accumulator = DashboardRefreshAccumulator()
        let group = DispatchGroup()

        group.enter()
        refreshWorker.async {
            accumulator.setServers(serverCollector.collect())
            group.leave()
        }
        group.enter()
        refreshWorker.async {
            accumulator.setRemoteConnections(remoteProjectCollector.collect())
            group.leave()
        }
        group.enter()
        refreshWorker.async {
            accumulator.setRemoteServices(remoteServiceController.collect())
            group.leave()
        }
        group.enter()
        refreshWorker.async {
            accumulator.setPublishStatuses(publishController.collect())
            group.leave()
        }
        group.enter()
        refreshWorker.async {
            accumulator.setActivityEvents(activityStore.load())
            group.leave()
        }
        group.enter()
        refreshWorker.async {
            accumulator.setUsage(usageCollector.collect())
            group.leave()
        }
        group.enter()
        refreshWorker.async {
            accumulator.setCaffeinateOn(caffeinate.isOn())
            group.leave()
        }
        group.enter()
        refreshWorker.async {
            accumulator.setClosedLidAwakeOn(closedLidAwake.isOn())
            group.leave()
        }

        group.notify(queue: .main) { [weak self] in
            let finishedAt = nowDate()
            let next = accumulator.snapshot(generatedAt: finishedAt)
            DispatchQueue.main.async {
                guard let self else { return }
                self.snapshot = next
                self.evaluateWatchdogs(using: next)
                self.isRefreshing = false
                self.lastFullRefreshAt = finishedAt
                self.lastRefreshDuration = finishedAt.timeIntervalSince(refreshStartedAt)
                runtimeLog("full refresh completed duration=\(String(format: "%.2f", self.lastRefreshDuration ?? 0))s servers=\(next.servers.count) remotes=\(next.remoteConnections.count) remoteServices=\(next.remoteServices.count)")
                let shouldRefreshAgain = self.refreshRequestedWhileRefreshing
                self.refreshRequestedWhileRefreshing = false
                let shouldUpdateOpenPopover = self.pendingPopoverUpdateAfterRefresh
                self.pendingPopoverUpdateAfterRefresh = false
                if self.currentMenu != nil {
                    self.rebuildMenu()
                }
                if shouldUpdateOpenPopover {
                    self.refreshPopoverContentIfShown()
                }
                if shouldRefreshAgain {
                    self.refresh(updateOpenPopover: shouldUpdateOpenPopover || self.popover?.isShown == true)
                }
            }
        }
    }

    @objc @MainActor private func refreshLocalStateIfPopoverOpen() {
        guard popover?.isShown == true,
              !isRefreshing,
              !isLocalRefreshing else { return }
        isLocalRefreshing = true

        let serverCollector = serverCollector
        let caffeinate = caffeinate
        let closedLidAwake = closedLidAwake
        refreshWorker.async { [weak self] in
            let servers = serverCollector.collect()
            let caffeinateOn = caffeinate.isOn()
            let closedLidAwakeOn = closedLidAwake.isOn()
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLocalRefreshing = false
                let changed = self.snapshot.servers != servers
                    || self.snapshot.caffeinateOn != caffeinateOn
                    || self.snapshot.closedLidAwakeOn != closedLidAwakeOn
                guard changed else { return }
                self.snapshot.servers = servers
                self.snapshot.caffeinateOn = caffeinateOn
                self.snapshot.closedLidAwakeOn = closedLidAwakeOn
                self.snapshot.generatedAt = nowDate()
                self.refreshPopoverContentIfShown()
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

        addHeader(brandingName, to: menu)
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

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.isEnabled = true
        menu.addItem(settingsItem)

        let openConfig = NSMenuItem(title: "Open server registry", action: #selector(openRegistry), keyEquivalent: "")
        openConfig.target = self
        openConfig.isEnabled = true
        menu.addItem(openConfig)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit \(brandingName)", action: #selector(quitApp), keyEquivalent: "q")
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
        refreshLocalStateIfPopoverOpen()
        if Date().timeIntervalSince(lastFullRefreshAt) > 20 {
            refresh(updateOpenPopover: true)
        }
    }

    @MainActor private func makeDashboardViewController(scrollOffset: CGFloat = 0) -> NSViewController {
        let viewController = NSViewController()
        let contentRoot = NSStackView()
        contentRoot.orientation = .vertical
        contentRoot.alignment = .leading
        contentRoot.spacing = 12
        contentRoot.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        contentRoot.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(contentRoot)
        NSLayoutConstraint.activate([
            contentRoot.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            contentRoot.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            contentRoot.topAnchor.constraint(equalTo: document.topAnchor),
            contentRoot.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalToConstant: Self.dashboardWidth)
        ])

        addProjectStackViews(to: contentRoot)
        addRemoteServiceViews(to: contentRoot)
        addServerViews(to: contentRoot)
        addPublishingViews(to: contentRoot)
        addActivityViews(to: contentRoot)
        addUsageViews(to: contentRoot)
        addRemoteProjectViews(to: contentRoot)

        document.layoutSubtreeIfNeeded()
        let contentHeight = max(1, contentRoot.fittingSize.height)
        document.frame = NSRect(x: 0, y: 0, width: Self.dashboardWidth, height: contentHeight)

        let header = makeDashboardHeaderView()
        let footer = makeDashboardFooterView()
        header.layoutSubtreeIfNeeded()
        footer.layoutSubtreeIfNeeded()
        let headerHeight = max(1, header.fittingSize.height)
        let footerHeight = max(1, footer.fittingSize.height)
        let availableScreenHeight = statusItem?.button?.window?.screen?.visibleFrame.height
            ?? NSScreen.main?.visibleFrame.height
            ?? 800
        let maximumHeight = max(420, min(740, availableScreenHeight - 80))
        let maximumScrollHeight = max(180, maximumHeight - headerHeight - footerHeight - 2)
        let viewportHeight = min(contentHeight, maximumScrollHeight)
        let totalHeight = headerHeight + viewportHeight + footerHeight + 2
        runtimeLog("dashboard v2 layout contentHeight=\(Int(contentHeight)) viewportHeight=\(Int(viewportHeight)) totalHeight=\(Int(totalHeight)) scrollable=\(contentHeight > viewportHeight)")

        let scrollView = NSScrollView()
        scrollView.identifier = NSUserInterfaceItemIdentifier("DashboardScrollView")
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = contentHeight > viewportHeight
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .automatic
        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView = document

        let topSeparator = separator()
        let bottomSeparator = separator()
        let outerStack = NSStackView(views: [header, topSeparator, scrollView, bottomSeparator, footer])
        outerStack.orientation = .vertical
        outerStack.alignment = .leading
        outerStack.spacing = 0
        outerStack.translatesAutoresizingMaskIntoConstraints = false

        let viewport = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: Self.dashboardWidth, height: totalHeight))
        viewport.material = .popover
        viewport.blendingMode = .behindWindow
        viewport.state = .active
        viewport.addSubview(outerStack)
        NSLayoutConstraint.activate([
            outerStack.leadingAnchor.constraint(equalTo: viewport.leadingAnchor),
            outerStack.trailingAnchor.constraint(equalTo: viewport.trailingAnchor),
            outerStack.topAnchor.constraint(equalTo: viewport.topAnchor),
            outerStack.bottomAnchor.constraint(equalTo: viewport.bottomAnchor),
            header.widthAnchor.constraint(equalToConstant: Self.dashboardWidth),
            footer.widthAnchor.constraint(equalToConstant: Self.dashboardWidth),
            scrollView.widthAnchor.constraint(equalToConstant: Self.dashboardWidth),
            scrollView.heightAnchor.constraint(equalToConstant: viewportHeight),
            topSeparator.widthAnchor.constraint(equalToConstant: Self.dashboardWidth),
            bottomSeparator.widthAnchor.constraint(equalToConstant: Self.dashboardWidth)
        ])

        viewController.view = viewport
        viewController.preferredContentSize = NSSize(width: Self.dashboardWidth, height: totalHeight)
        if scrollOffset > 0 {
            DispatchQueue.main.async {
                let maximumOffset = max(0, document.bounds.height - scrollView.contentView.bounds.height)
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(scrollOffset, maximumOffset)))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
        return viewController
    }

    @MainActor private func refreshPopoverContentIfShown() {
        guard let popover, popover.isShown else { return }
        let scrollOffset = popover.contentViewController
            .flatMap { dashboardScrollView(in: $0.view) }?
            .contentView.bounds.origin.y ?? 0
        popover.contentViewController = makeDashboardViewController(scrollOffset: scrollOffset)
    }

    @MainActor private func dashboardScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView,
           scrollView.identifier?.rawValue == "DashboardScrollView" {
            return scrollView
        }
        for subview in view.subviews {
            if let match = dashboardScrollView(in: subview) {
                return match
            }
        }
        return nil
    }

    @MainActor private func makeDashboardHeaderView() -> NSView {
        let header = NSStackView()
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 9
        header.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 12, right: 16)

        let logoView = NSImageView()
        if let logo = configuredStatusImage() {
            logo.isTemplate = true
            logoView.image = logo
        }
        logoView.contentTintColor = .labelColor
        logoView.imageScaling = .scaleProportionallyUpOrDown
        NSLayoutConstraint.activate([
            logoView.widthAnchor.constraint(equalToConstant: 34),
            logoView.heightAnchor.constraint(equalToConstant: 34)
        ])

        let titles = NSStackView()
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 1
        titles.addArrangedSubview(label(brandingName, font: .systemFont(ofSize: 14, weight: .bold)))
        titles.addArrangedSubview(label(
            isRefreshing ? "Refreshing infrastructure state…" : brandingSubtitle,
            font: .systemFont(ofSize: 11),
            color: isRefreshing ? .systemOrange : .secondaryLabelColor
        ))

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let refreshButton = ActionButton(title: "Refresh", symbolName: "arrow.clockwise") { [weak self] in
            Task { @MainActor in self?.refresh(updateOpenPopover: true) }
        }
        refreshButton.isEnabled = !isRefreshing

        let titleRow = NSStackView(views: [logoView, titles, spacer, refreshButton])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 10
        titleRow.widthAnchor.constraint(equalToConstant: Self.cardWidth).isActive = true
        header.addArrangedSubview(titleRow)

        let runningCount = snapshot.servers.filter(\.isRunning).count
        let serverPill = StatusPill(
            text: "\(runningCount) live server\(runningCount == 1 ? "" : "s")",
            symbolName: "server.rack",
            color: runningCount > 0 ? .systemGreen : .secondaryLabelColor
        )
        let connectedCount = snapshot.remoteServices.isEmpty
            ? snapshot.remoteConnections.filter { $0.statusTitle == "Connected" }.count
            : snapshot.remoteServices.filter { $0.running && $0.healthOK != false }.count
        let remoteTotal = snapshot.remoteServices.isEmpty ? snapshot.remoteConnections.count : snapshot.remoteServices.count
        let remoteColor: NSColor = remoteTotal == 0
            ? .secondaryLabelColor
            : (connectedCount == remoteTotal ? .systemGreen : .systemOrange)
        let remotePill = StatusPill(
            text: "\(connectedCount)/\(remoteTotal) remote",
            symbolName: "network",
            color: remoteColor
        )
        let updatePill = StatusPill(
            text: isRefreshing ? "Refreshing" : "Updated \(timeOnly(snapshot.generatedAt))",
            symbolName: isRefreshing ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill",
            color: isRefreshing ? .systemOrange : .secondaryLabelColor
        )
        let summaryRow = NSStackView(views: [serverPill, remotePill, updatePill])
        summaryRow.orientation = .horizontal
        summaryRow.alignment = .centerY
        summaryRow.spacing = 6
        summaryRow.widthAnchor.constraint(lessThanOrEqualToConstant: Self.cardWidth).isActive = true
        header.addArrangedSubview(summaryRow)

        let caffeinateButton = ActionButton(
            title: snapshot.caffeinateOn ? "Caffeinate On" : "Caffeinate Off",
            symbolName: "cup.and.saucer.fill"
        ) { [weak self] in
            Task { @MainActor in self?.toggleCaffeinateDirect() }
        }
        caffeinateButton.contentTintColor = snapshot.caffeinateOn ? .systemGreen : .secondaryLabelColor
        caffeinateButton.toolTip = "Prevent idle and display sleep"

        let lidButton = ActionButton(
            title: snapshot.closedLidAwakeOn ? "Lid Awake On" : "Lid Awake Off",
            symbolName: "laptopcomputer"
        ) { [weak self] in
            Task { @MainActor in self?.toggleClosedLidAwakeDirect() }
        }
        lidButton.contentTintColor = snapshot.closedLidAwakeOn ? .systemGreen : .secondaryLabelColor
        lidButton.toolTip = "Keep the Mac awake with the lid closed"

        let powerRow = NSStackView(views: [caffeinateButton, lidButton])
        powerRow.orientation = .horizontal
        powerRow.alignment = .centerY
        powerRow.spacing = 8
        header.addArrangedSubview(powerRow)
        return header
    }

    @MainActor private func makeDashboardFooterView() -> NSView {
        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 7
        footer.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 9, right: 16)

        let timingText: String
        if isRefreshing {
            timingText = "Refreshing…"
        } else if let lastRefreshDuration {
            timingText = String(format: "Live · full refresh %.1fs", lastRefreshDuration)
        } else {
            timingText = "Live local updates"
        }
        footer.addArrangedSubview(label(timingText, font: .systemFont(ofSize: 10.5), color: .secondaryLabelColor))

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        footer.addArrangedSubview(spacer)

        footer.addArrangedSubview(ActionButton(title: "Settings", symbolName: "gearshape") { [weak self] in
            Task { @MainActor in self?.openSettingsDirect() }
        })
        footer.addArrangedSubview(ActionButton(title: "Registry", symbolName: "list.bullet.rectangle") {
            let path = homePath(".codex-menu-bar/servers.json")
            if !FileManager.default.fileExists(atPath: path) {
                ServerRegistry().save(ServerRegistryData())
            }
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        })
        footer.addArrangedSubview(ActionButton(title: "Quit", symbolName: "xmark.circle") {
            NSApplication.shared.terminate(nil)
        })
        return footer
    }

    @MainActor private func addProjectStackViews(to root: NSStackView) {
        root.addArrangedSubview(sectionHeader(
            title: "Project Stacks · \(config.projectStacks.count)",
            symbolName: "square.3.layers.3d",
            sectionID: "stacks"
        ))
        guard !collapsedSectionIDs.contains("stacks") else { return }
        guard !config.projectStacks.isEmpty else {
            root.addArrangedSubview(emptyStateCard(
                title: "No project stacks configured",
                detail: "Stacks group local and remote services into one-click workflows.",
                symbolName: "square.3.layers.3d"
            ))
            return
        }

        for stack in config.projectStacks {
            let localStatuses = stack.localServiceIDs.compactMap { id in snapshot.servers.first { $0.id == id } }
            let remoteStatuses = stack.remoteServiceIDs.compactMap { id in snapshot.remoteServices.first { $0.config.id == id } }
            let total = stack.localServiceIDs.count + stack.remoteServiceIDs.count
            let running = localStatuses.filter(\.isRunning).count + remoteStatuses.filter(\.running).count
            let busy = stackActionsInProgress.contains(stack.id)
            let statusColor: NSColor = busy ? .systemOrange : (running == total && total > 0 ? .systemGreen : (running > 0 ? .systemOrange : .secondaryLabelColor))

            let inner = NSStackView()
            inner.orientation = .vertical
            inner.alignment = .leading
            inner.spacing = 7
            let titleLabel = label(stack.name, font: .systemFont(ofSize: 12.5, weight: .semibold))
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let status = StatusPill(
                text: busy ? "Working…" : "\(running)/\(total) running",
                symbolName: busy ? "arrow.triangle.2.circlepath" : (running == total && total > 0 ? "checkmark.circle.fill" : "circle.dashed"),
                color: statusColor
            )
            let titleRow = NSStackView(views: [titleLabel, spacer, status])
            titleRow.orientation = .horizontal
            titleRow.alignment = .centerY
            titleRow.widthAnchor.constraint(equalToConstant: Self.cardWidth - 24).isActive = true
            inner.addArrangedSubview(titleRow)

            let serviceNames = stack.localServiceIDs.compactMap { id in config.localServices.first { $0.id == id }?.name }
                + stack.remoteServiceIDs.compactMap { id in config.remoteServices.first { $0.id == id }?.name }
            inner.addArrangedSubview(label(serviceNames.joined(separator: " · "), font: .systemFont(ofSize: 10.5), color: .secondaryLabelColor))

            let buttons = row()
            let start = ActionButton(title: "Start Stack", symbolName: "play.fill") { [weak self] in
                Task { @MainActor in self?.startStackDirect(stack) }
            }
            start.isEnabled = !busy && running < total
            buttons.addArrangedSubview(start)
            let stop = ActionButton(title: "Stop Stack", symbolName: "stop.fill") { [weak self] in
                Task { @MainActor in self?.stopStackDirect(stack) }
            }
            stop.isEnabled = !busy && running > 0
            buttons.addArrangedSubview(stop)
            inner.addArrangedSubview(buttons)
            root.addArrangedSubview(cardView(containing: inner, accentColor: statusColor))
        }
    }

    @MainActor private func addRemoteServiceViews(to root: NSStackView) {
        root.addArrangedSubview(sectionHeader(
            title: "Remote Services · \(snapshot.remoteServices.count)",
            symbolName: "desktopcomputer",
            sectionID: "remote-services"
        ))
        guard !collapsedSectionIDs.contains("remote-services") else { return }
        guard !snapshot.remoteServices.isEmpty else {
            root.addArrangedSubview(emptyStateCard(
                title: "No remote services configured",
                detail: "Remote LaunchAgents can be managed here over the existing SSH connection.",
                symbolName: "desktopcomputer"
            ))
            return
        }

        for service in snapshot.remoteServices {
            let id = service.config.id
            let action = remoteServiceActionsInProgress[id]
            let healthy = service.running && service.healthOK != false
            let color: NSColor = action != nil ? .systemOrange : (healthy ? .systemGreen : (service.running ? .systemOrange : .secondaryLabelColor))
            let inner = NSStackView()
            inner.orientation = .vertical
            inner.alignment = .leading
            inner.spacing = 6

            let titleLabel = label(service.config.name, font: .systemFont(ofSize: 12.5, weight: .semibold))
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let state = StatusPill(
                text: action ?? (healthy ? "Healthy" : service.detail),
                symbolName: action != nil ? "arrow.triangle.2.circlepath" : (healthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"),
                color: color
            )
            let titleRow = NSStackView(views: [titleLabel, spacer, state])
            titleRow.orientation = .horizontal
            titleRow.alignment = .centerY
            titleRow.widthAnchor.constraint(equalToConstant: Self.cardWidth - 24).isActive = true
            inner.addArrangedSubview(titleRow)
            inner.addArrangedSubview(label("\(service.config.target) · port \(service.config.port)", font: .monospacedSystemFont(ofSize: 10.5, weight: .regular), color: .secondaryLabelColor))
            if let telemetry = telemetryText(cpu: service.cpuPercent, memoryBytes: service.memoryBytes, uptime: service.uptimeText, listeners: service.running ? 1 : 0, conflict: false) {
                inner.addArrangedSubview(label(telemetry, font: .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular), color: .tertiaryLabelColor))
            }
            if let message = remoteServiceActionMessages[id] {
                inner.addArrangedSubview(label(message, color: message.lowercased().contains("fail") ? .systemRed : .secondaryLabelColor))
            }

            let buttons = row()
            let startStop = ActionButton(
                title: service.running ? "Stop" : "Start",
                symbolName: service.running ? "stop.fill" : "play.fill"
            ) { [weak self] in
                Task { @MainActor in self?.performRemoteServiceAction(service.running ? .stop : .start, status: service) }
            }
            startStop.isEnabled = action == nil
            buttons.addArrangedSubview(startStop)
            let restart = ActionButton(title: "Restart", symbolName: "arrow.clockwise") { [weak self] in
                Task { @MainActor in self?.performRemoteServiceAction(.restart, status: service) }
            }
            restart.isEnabled = action == nil
            buttons.addArrangedSubview(restart)
            if !service.config.logPaths.isEmpty {
                let logs = ActionButton(title: "Logs", symbolName: "doc.text.magnifyingglass") { [weak self] in
                    Task { @MainActor in self?.openRemoteServiceLogs(service) }
                }
                logs.isEnabled = action == nil
                buttons.addArrangedSubview(logs)
            }
            let remoteWatchTitle = watchdogSuppressedIDs.contains("remote:\(id)") ? "Watchdog Paused" : watchdogButtonTitle(service.config.watchdog)
            let watch = ActionButton(title: remoteWatchTitle, symbolName: "shield.checkered") { [weak self] in
                Task { @MainActor in self?.cycleRemoteWatchdog(id: id) }
            }
            watch.toolTip = "Cycles Off → Notify → Auto-restart"
            buttons.addArrangedSubview(watch)
            inner.addArrangedSubview(buttons)
            root.addArrangedSubview(cardView(containing: inner, accentColor: color))
        }
    }

    @MainActor private func addPublishingViews(to root: NSStackView) {
        root.addArrangedSubview(sectionHeader(
            title: "Secure Sharing · \(snapshot.publishStatuses.count)",
            symbolName: "network.badge.shield.half.filled",
            sectionID: "sharing"
        ))
        guard !collapsedSectionIDs.contains("sharing") else { return }
        guard !snapshot.publishStatuses.isEmpty else {
            root.addArrangedSubview(emptyStateCard(
                title: "No sharing targets configured",
                detail: "Tailscale Serve and Funnel targets remain opt-in.",
                symbolName: "lock.shield"
            ))
            return
        }

        for status in snapshot.publishStatuses {
            let busy = publishActionsInProgress.contains(status.config.id)
            let color: NSColor = busy ? .systemOrange : (status.mode == .funnel ? .systemRed : (status.mode == .tailnet ? .systemBlue : .secondaryLabelColor))
            let inner = NSStackView()
            inner.orientation = .vertical
            inner.alignment = .leading
            inner.spacing = 6
            let titleLabel = label(status.config.name, font: .systemFont(ofSize: 12.5, weight: .semibold))
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let modeText = busy ? "Updating…" : (status.mode == .off ? "Off" : (status.mode == .tailnet ? "Tailnet Only" : "Public Funnel"))
            let pill = StatusPill(text: modeText, symbolName: status.mode == .funnel ? "globe.americas.fill" : "lock.shield.fill", color: color)
            let titleRow = NSStackView(views: [titleLabel, spacer, pill])
            titleRow.orientation = .horizontal
            titleRow.alignment = .centerY
            titleRow.widthAnchor.constraint(equalToConstant: Self.cardWidth - 24).isActive = true
            inner.addArrangedSubview(titleRow)
            inner.addArrangedSubview(label("Local port \(status.config.port) · \(status.detail)", color: .secondaryLabelColor))
            if let url = status.url {
                inner.addArrangedSubview(label(url, font: .monospacedSystemFont(ofSize: 10.5, weight: .regular), color: .systemBlue))
            }
            if let message = publishActionMessages[status.config.id] {
                inner.addArrangedSubview(label(message, color: message.lowercased().contains("fail") ? .systemRed : .secondaryLabelColor))
            }

            let buttons = row()
            let privateShare = ActionButton(title: "Tailnet", symbolName: "person.2.badge.gearshape") { [weak self] in
                Task { @MainActor in self?.setPublishModeDirect(.tailnet, status: status) }
            }
            privateShare.isEnabled = !busy && status.mode != .tailnet
            buttons.addArrangedSubview(privateShare)
            let publicShare = ActionButton(title: "Public", symbolName: "globe.americas") { [weak self] in
                Task { @MainActor in self?.setPublishModeDirect(.funnel, status: status) }
            }
            publicShare.contentTintColor = .systemRed
            publicShare.isEnabled = !busy && status.mode != .funnel
            buttons.addArrangedSubview(publicShare)
            let off = ActionButton(title: "Turn Off", symbolName: "lock.fill") { [weak self] in
                Task { @MainActor in self?.setPublishModeDirect(.off, status: status) }
            }
            off.isEnabled = !busy && status.mode != .off
            buttons.addArrangedSubview(off)
            if let url = status.url, let parsed = URL(string: url) {
                buttons.addArrangedSubview(ActionButton(title: "Open", symbolName: "safari") {
                    NSWorkspace.shared.open(parsed)
                })
            }
            inner.addArrangedSubview(buttons)
            root.addArrangedSubview(cardView(containing: inner, accentColor: color))
        }
    }

    @MainActor private func addActivityViews(to root: NSStackView) {
        var actions: [NSView] = []
        if !snapshot.activityEvents.isEmpty {
            actions.append(ActionButton(title: "Open", symbolName: "doc.text") { [weak self] in
                guard let self else { return }
                NSWorkspace.shared.open(URL(fileURLWithPath: self.activityStore.path))
            })
            actions.append(ActionButton(title: "Clear", symbolName: "trash") { [weak self] in
                Task { @MainActor in self?.clearActivityDirect() }
            })
        }
        root.addArrangedSubview(sectionHeader(
            title: "Activity · \(snapshot.activityEvents.count)",
            symbolName: "clock.arrow.circlepath",
            sectionID: "activity",
            trailingViews: actions
        ))
        guard !collapsedSectionIDs.contains("activity") else { return }
        guard !snapshot.activityEvents.isEmpty else {
            root.addArrangedSubview(emptyStateCard(
                title: "No operations recorded yet",
                detail: "Starts, stops, failures, watchdog events, and sharing changes appear here.",
                symbolName: "clock"
            ))
            return
        }

        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 7
        for event in snapshot.activityEvents.prefix(8) {
            let color = activityColor(event.level)
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3
            dot.layer?.backgroundColor = color.cgColor
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 6),
                dot.heightAnchor.constraint(equalToConstant: 6)
            ])
            let text = label("\(timeOnly(event.date)) · \(event.title)", font: .systemFont(ofSize: 10.5, weight: .medium))
            text.toolTip = event.detail
            let eventRow = NSStackView(views: [dot, text])
            eventRow.orientation = .horizontal
            eventRow.alignment = .centerY
            eventRow.spacing = 7
            inner.addArrangedSubview(eventRow)
        }
        root.addArrangedSubview(cardView(containing: inner, accentColor: .secondaryLabelColor))
    }

    @MainActor private func addUsageViews(to root: NSStackView) {
        root.addArrangedSubview(sectionHeader(title: "Codex Usage", symbolName: "gauge.with.dots.needle.67percent", sectionID: "usage"))
        guard !collapsedSectionIDs.contains("usage") else { return }
        guard let usage = snapshot.usage else {
            root.addArrangedSubview(emptyStateCard(
                title: "Usage data is not available yet",
                detail: "Open Codex once, then refresh this dashboard.",
                symbolName: "chart.bar.xaxis"
            ))
            return
        }

        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 9
        if let plan = usage.planType {
            inner.addArrangedSubview(StatusPill(text: plan.capitalized, symbolName: "person.crop.circle.fill", color: .systemBlue))
        }
        if let primary = usage.primary {
            inner.addArrangedSubview(usageProgressView(
                title: "Primary · \(shortWindowLabel(primary.windowMinutes))",
                limit: primary
            ))
        }
        if let secondary = usage.secondary {
            inner.addArrangedSubview(usageProgressView(title: "Weekly", limit: secondary))
        }
        if let observedAt = usage.observedAt {
            inner.addArrangedSubview(label("Observed \(relativeAge(observedAt)) ago", font: .systemFont(ofSize: 10.5), color: .secondaryLabelColor))
        }
        root.addArrangedSubview(cardView(containing: inner, accentColor: .systemBlue))
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
        root.addArrangedSubview(sectionHeader(
            title: "Remote Hosts · \(snapshot.remoteConnections.count)",
            symbolName: "network",
            sectionID: "connections"
        ))
        guard !collapsedSectionIDs.contains("connections") else { return }
        guard !snapshot.remoteConnections.isEmpty else {
            root.addArrangedSubview(emptyStateCard(
                title: "No remote hosts configured",
                detail: "Remote Codex connections will appear here automatically.",
                symbolName: "network.slash"
            ))
            return
        }

        for connection in snapshot.remoteConnections {
            let inner = NSStackView()
            inner.orientation = .vertical
            inner.alignment = .leading
            inner.spacing = 6

            let titleLabel = label(remoteConnectionTitle(connection), font: .systemFont(ofSize: 12.5, weight: .semibold))
            let titleSpacer = NSView()
            titleSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let statusColor = remoteStatusColor(connection)
            let status = StatusPill(
                text: connection.statusTitle,
                symbolName: connection.statusTitle == "Connected" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                color: statusColor
            )
            let titleRow = NSStackView(views: [titleLabel, titleSpacer, status])
            titleRow.orientation = .horizontal
            titleRow.alignment = .centerY
            titleRow.spacing = 8
            titleRow.widthAnchor.constraint(equalToConstant: Self.cardWidth - 24).isActive = true
            inner.addArrangedSubview(titleRow)

            inner.addArrangedSubview(label(connection.detail, color: .secondaryLabelColor))
            inner.addArrangedSubview(label(remoteConnectionMeta(connection), font: .systemFont(ofSize: 10.5), color: .tertiaryLabelColor))
            if !connection.projectLabels.isEmpty {
                inner.addArrangedSubview(label(
                    connection.projectLabels.prefix(6).joined(separator: " · "),
                    font: .systemFont(ofSize: 10.5),
                    color: .secondaryLabelColor
                ))
            }

            let buttons = row()
            buttons.addArrangedSubview(ActionButton(title: "Reconnect", symbolName: "arrow.triangle.2.circlepath") { [weak self] in
                Task { @MainActor in self?.refreshRemoteConnectionDirect(connection) }
            })
            if let authURL = connection.authURL {
                buttons.addArrangedSubview(ActionButton(title: "Tailscale Check", symbolName: "checkmark.shield") {
                    if let url = URL(string: authURL) {
                        NSWorkspace.shared.open(url)
                    }
                })
            }
            inner.addArrangedSubview(buttons)

            root.addArrangedSubview(cardView(containing: inner, accentColor: statusColor))
        }
    }

    @MainActor private func addServerViews(to root: NSStackView) {
        let runningServers = snapshot.servers.filter(\.isRunning)
        let managedIDs = Set(config.localServices.map(\.id))
        let stoppedServers = snapshot.servers.filter { !$0.isRunning && !managedIDs.contains($0.id) }
        var headerActions: [NSView] = []
        if !runningServers.isEmpty {
            headerActions.append(ActionButton(title: "Stop All", symbolName: "stop.circle") { [weak self] in
                Task { @MainActor in self?.stopAllServersDirect() }
            })
        }
        if !stoppedServers.isEmpty {
            headerActions.append(ActionButton(title: "Clear Stopped", symbolName: "trash") { [weak self] in
                Task { @MainActor in self?.clearStoppedServersDirect() }
            })
        }
        root.addArrangedSubview(sectionHeader(
            title: "Local Web Servers · \(snapshot.servers.count)",
            symbolName: "server.rack",
            sectionID: "local-servers",
            trailingViews: headerActions
        ))
        guard !collapsedSectionIDs.contains("local-servers") else { return }
        guard !snapshot.servers.isEmpty else {
            root.addArrangedSubview(emptyStateCard(
                title: "No local web servers detected",
                detail: "Vite, Next.js, Node, Python, and other project listeners will appear automatically.",
                symbolName: "server.rack"
            ))
            return
        }
        for server in snapshot.servers {
            let actionInProgress = serverActionsInProgress[server.id]
            let inner = NSStackView()
            inner.orientation = .vertical
            inner.alignment = .leading
            inner.spacing = 6

            let titleLabel = label(server.displayTitle, font: .systemFont(ofSize: 12.5, weight: .semibold))
            let titleSpacer = NSView()
            titleSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let stateText = actionInProgress ?? (server.isRunning ? "Running · PID \(server.pid.map(String.init) ?? "?")" : "Stopped")
            let stateColor: NSColor = actionInProgress != nil ? .systemOrange : (server.isRunning ? .systemGreen : .secondaryLabelColor)
            let stateSymbol = actionInProgress != nil ? "arrow.triangle.2.circlepath" : (server.isRunning ? "play.circle.fill" : "stop.circle")
            let statePill = StatusPill(text: stateText, symbolName: stateSymbol, color: stateColor)
            let titleRow = NSStackView(views: [titleLabel, titleSpacer, statePill])
            titleRow.orientation = .horizontal
            titleRow.alignment = .centerY
            titleRow.spacing = 8
            titleRow.widthAnchor.constraint(equalToConstant: Self.cardWidth - 24).isActive = true
            inner.addArrangedSubview(titleRow)

            if let telemetry = telemetryText(
                cpu: server.cpuPercent,
                memoryBytes: server.memoryBytes,
                uptime: server.uptimeText,
                listeners: server.listenerCount,
                conflict: server.portConflict
            ) {
                inner.addArrangedSubview(label(
                    telemetry,
                    font: .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular),
                    color: server.portConflict ? .systemOrange : .tertiaryLabelColor
                ))
            }

            if let message = serverActionMessages[server.id] {
                inner.addArrangedSubview(label(message, color: message.hasPrefix("Could not") ? .systemRed : .secondaryLabelColor))
            }
            inner.addArrangedSubview(label(abbreviatePath(server.cwd), font: .monospacedSystemFont(ofSize: 10.5, weight: .regular), color: .secondaryLabelColor))
            if let startCommand = server.startCommand {
                inner.addArrangedSubview(label("$ \(startCommand)", font: .monospacedSystemFont(ofSize: 10.5, weight: .regular), color: .tertiaryLabelColor))
            }

            if let managed = config.localServices.first(where: { $0.id == server.id }) {
                let localWatchTitle = watchdogSuppressedIDs.contains("local:\(managed.id)") ? "Watchdog Paused" : watchdogButtonTitle(managed.watchdog)
                let watchButton = ActionButton(title: localWatchTitle, symbolName: "shield.checkered") { [weak self] in
                    Task { @MainActor in self?.cycleLocalWatchdog(id: managed.id) }
                }
                watchButton.toolTip = "Cycles Off → Notify → Auto-restart"
                inner.addArrangedSubview(watchButton)
            }

            let buttons = row()
            let openButton = ActionButton(title: "Open", symbolName: "safari") { [weak self] in
                Task { @MainActor in self?.openServerDirect(server) }
            }
            openButton.isEnabled = server.isRunning && actionInProgress == nil
            buttons.addArrangedSubview(openButton)

            let copyButton = ActionButton(title: "Copy", symbolName: "doc.on.doc") { [weak self] in
                Task { @MainActor in self?.copyServerURLDirect(server) }
            }
            copyButton.isEnabled = server.urlString != nil && actionInProgress == nil
            copyButton.toolTip = "Copy the localhost URL"
            buttons.addArrangedSubview(copyButton)

            if server.cwd != nil {
                let folderButton = ActionButton(title: "", symbolName: "folder") { [weak self] in
                    Task { @MainActor in self?.openServerFolderDirect(server) }
                }
                folderButton.toolTip = "Open project folder"
                folderButton.setAccessibilityLabel("Open project folder")
                folderButton.isEnabled = actionInProgress == nil
                buttons.addArrangedSubview(folderButton)
            }

            if FileManager.default.fileExists(atPath: serverLogPath(server.id)) {
                let logsButton = ActionButton(title: "", symbolName: "doc.text.magnifyingglass") { [weak self] in
                    Task { @MainActor in self?.openServerLogDirect(server) }
                }
                logsButton.toolTip = "Open server log"
                logsButton.setAccessibilityLabel("Open server log")
                logsButton.isEnabled = actionInProgress == nil
                buttons.addArrangedSubview(logsButton)
            }

            let startStopButton = ActionButton(
                title: server.isRunning ? "Stop" : "Start",
                symbolName: server.isRunning ? "stop.fill" : "play.fill"
            ) { [weak self] in
                Task { @MainActor in
                    server.isRunning ? self?.stopServerDirect(server) : self?.startServerDirect(server)
                }
            }
            startStopButton.isEnabled = actionInProgress == nil
                && (server.isRunning || (server.startCommand != nil && server.cwd != nil))
            buttons.addArrangedSubview(startStopButton)

            if !config.localServices.contains(where: { $0.id == server.id }) {
                let removeButton = ActionButton(title: "Remove", symbolName: "trash") { [weak self] in
                    Task { @MainActor in self?.removeServerDirect(server) }
                }
                removeButton.isEnabled = actionInProgress == nil
                buttons.addArrangedSubview(removeButton)
            }
            inner.addArrangedSubview(buttons)

            root.addArrangedSubview(cardView(containing: inner, accentColor: stateColor))
        }
    }

    @MainActor private func sectionHeader(
        title: String,
        symbolName: String,
        sectionID: String? = nil,
        trailingViews: [NSView] = []
    ) -> NSStackView {
        let imageView = NSImageView()
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title) {
            image.isTemplate = true
            imageView.image = image
        }
        imageView.contentTintColor = .secondaryLabelColor
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        imageView.widthAnchor.constraint(equalToConstant: 16).isActive = true

        let titleLabel = label(title, font: .systemFont(ofSize: 12.5, weight: .semibold))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var actionViews = trailingViews
        if let sectionID {
            let collapsed = collapsedSectionIDs.contains(sectionID)
            let disclosure = ActionButton(title: "", symbolName: collapsed ? "chevron.right" : "chevron.down") { [weak self] in
                Task { @MainActor in self?.toggleSection(sectionID) }
            }
            disclosure.toolTip = collapsed ? "Expand section" : "Collapse section"
            disclosure.setAccessibilityLabel(disclosure.toolTip ?? "Toggle section")
            actionViews.append(disclosure)
        }
        let views = [imageView, titleLabel, spacer] + actionViews
        let header = NSStackView(views: views)
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 7
        header.widthAnchor.constraint(equalToConstant: Self.cardWidth).isActive = true
        return header
    }

    @MainActor private func toggleSection(_ id: String) {
        if collapsedSectionIDs.contains(id) {
            collapsedSectionIDs.remove(id)
        } else {
            collapsedSectionIDs.insert(id)
        }
        UserDefaults.standard.set(Array(collapsedSectionIDs).sorted(), forKey: "collapsedDashboardSections")
        refreshPopoverContentIfShown()
    }

    @MainActor private func cardView(containing inner: NSStackView, accentColor: NSColor? = nil) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 1
        card.layer?.borderColor = (accentColor ?? .separatorColor).withAlphaComponent(0.28).cgColor
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.42).cgColor
        inner.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            inner.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
            card.widthAnchor.constraint(equalToConstant: Self.cardWidth)
        ])
        return card
    }

    @MainActor private func emptyStateCard(title: String, detail: String, symbolName: String) -> NSView {
        let imageView = NSImageView()
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title) {
            image.isTemplate = true
            imageView.image = image
        }
        imageView.contentTintColor = .tertiaryLabelColor
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 24, weight: .regular)
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 32),
            imageView.heightAnchor.constraint(equalToConstant: 32)
        ])

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.addArrangedSubview(label(title, font: .systemFont(ofSize: 11.5, weight: .medium), color: .secondaryLabelColor))
        textStack.addArrangedSubview(label(detail, font: .systemFont(ofSize: 10.5), color: .tertiaryLabelColor))

        let inner = NSStackView(views: [imageView, textStack])
        inner.orientation = .horizontal
        inner.alignment = .centerY
        inner.spacing = 10
        return cardView(containing: inner)
    }

    @MainActor private func usageProgressView(title: String, limit: CodexLimit) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 4

        let titleLabel = label(title, font: .systemFont(ofSize: 11, weight: .medium))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let valueLabel = label("\(limit.usedPercent)% used", font: .monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold), color: usageColor(limit.usedPercent))
        let titleRow = NSStackView(views: [titleLabel, spacer, valueLabel])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.widthAnchor.constraint(equalToConstant: Self.cardWidth - 24).isActive = true
        container.addArrangedSubview(titleRow)

        let progressWidth = Self.cardWidth - 24
        let progress = NSView()
        progress.wantsLayer = true
        progress.layer?.cornerRadius = 3
        progress.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        let progressFill = NSView()
        progressFill.wantsLayer = true
        progressFill.layer?.cornerRadius = 3
        progressFill.layer?.backgroundColor = usageColor(limit.usedPercent).cgColor
        progressFill.translatesAutoresizingMaskIntoConstraints = false
        progress.addSubview(progressFill)
        NSLayoutConstraint.activate([
            progress.widthAnchor.constraint(equalToConstant: progressWidth),
            progress.heightAnchor.constraint(equalToConstant: 6),
            progressFill.leadingAnchor.constraint(equalTo: progress.leadingAnchor),
            progressFill.topAnchor.constraint(equalTo: progress.topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: progress.bottomAnchor),
            progressFill.widthAnchor.constraint(equalToConstant: progressWidth * CGFloat(min(100, max(0, limit.usedPercent))) / 100)
        ])
        container.addArrangedSubview(progress)
        container.addArrangedSubview(label("Resets \(resetText(limit.resetAt))", font: .systemFont(ofSize: 10), color: .tertiaryLabelColor))
        return container
    }

    private func usageColor(_ usedPercent: Int) -> NSColor {
        if usedPercent >= 85 { return .systemRed }
        if usedPercent >= 65 { return .systemOrange }
        return .systemBlue
    }

    private func telemetryText(
        cpu: Double?,
        memoryBytes: Int64?,
        uptime: String?,
        listeners: Int,
        conflict: Bool
    ) -> String? {
        var parts: [String] = []
        if let cpu { parts.append(String(format: "CPU %.1f%%", cpu)) }
        if let memoryBytes {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .memory
            parts.append("RAM \(formatter.string(fromByteCount: memoryBytes))")
        }
        if let uptime, !uptime.isEmpty { parts.append("up \(uptime)") }
        if listeners > 1 { parts.append("\(listeners) listeners") }
        if conflict { parts.append("port conflict") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func watchdogButtonTitle(_ policy: WatchdogPolicyConfig) -> String {
        guard policy.enabled else { return "Watchdog Off" }
        if policy.autoRestart { return "Auto Restart" }
        if policy.notifications { return "Notify on Failure" }
        return "Watchdog On"
    }

    private func setWatchdogSuppressed(_ key: String, _ suppressed: Bool) {
        if suppressed {
            watchdogSuppressedIDs.insert(key)
        } else {
            watchdogSuppressedIDs.remove(key)
        }
        UserDefaults.standard.set(Array(watchdogSuppressedIDs).sorted(), forKey: "suppressedWatchdogs")
    }

    private func activityColor(_ level: ActivityLevel) -> NSColor {
        switch level {
        case .info: return .systemBlue
        case .success: return .systemGreen
        case .warning: return .systemOrange
        case .error: return .systemRed
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

            if !config.localServices.contains(where: { $0.id == server.id }) {
                let removeTitle = server.isRunning ? "Stop and remove from menu" : "Remove from menu"
                let remove = NSMenuItem(title: removeTitle, action: #selector(removeServer), keyEquivalent: "")
                remove.target = self
                remove.representedObject = server
                remove.isEnabled = true
                submenu.addItem(remove)
            }

            item.submenu = submenu
            menu.addItem(item)
        }

        if snapshot.servers.contains(where: \.isRunning) {
            menu.addItem(.separator())
            let stopAll = NSMenuItem(title: "Stop all running servers", action: #selector(stopAllServers), keyEquivalent: "")
            stopAll.target = self
            stopAll.isEnabled = true
            menu.addItem(stopAll)
        }
        let managedIDs = Set(config.localServices.map(\.id))
        if snapshot.servers.contains(where: { !$0.isRunning && !managedIDs.contains($0.id) }) {
            let clearStopped = NSMenuItem(title: "Clear stopped servers", action: #selector(clearStoppedServers), keyEquivalent: "")
            clearStopped.target = self
            clearStopped.isEnabled = true
            menu.addItem(clearStopped)
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
        if NSApp.currentEvent?.type == .rightMouseUp,
           let button = statusItem?.button {
            if popover?.isShown == true {
                popover?.performClose(nil)
            }
            rebuildMenu()
            currentMenu?.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 3), in: button)
            currentMenu = nil
            return
        }
        showDashboardPopover()
    }

    @objc @MainActor private func toggleCaffeinate() {
        toggleCaffeinateDirect()
    }

    @MainActor private func toggleCaffeinateDirect() {
        let desiredState = !snapshot.caffeinateOn
        updatePowerState(caffeinateOn: desiredState)
        let caffeinate = caffeinate
        let activityStore = activityStore
        caffeinateWorker.async { [weak self] in
            if desiredState {
                caffeinate.turnOn()
            } else {
                caffeinate.turnOff()
            }
            let actualState = caffeinate.isOn()
            activityStore.record(category: "power", title: "Caffeinate \(actualState ? "enabled" : "disabled")", detail: "Power assertion updated", level: actualState == desiredState ? .success : .error)
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
        let activityStore = activityStore
        closedLidWorker.async { [weak self] in
            if desiredState {
                closedLidAwake.turnOn()
            } else {
                closedLidAwake.turnOff()
            }
            let actualState = closedLidAwake.isOn()
            activityStore.record(category: "power", title: "Closed-lid awake \(actualState ? "enabled" : "disabled")", detail: "Sleep policy updated", level: actualState == desiredState ? .success : .error)
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

    @MainActor private func copyServerURLDirect(_ server: WebServer) {
        guard let urlString = server.urlString else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urlString, forType: .string)
        serverActionMessages[server.id] = "Copied \(urlString)"
        refreshPopoverContentIfShown()
    }

    @MainActor private func openServerFolderDirect(_ server: WebServer) {
        guard let cwd = server.cwd else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
    }

    @MainActor private func openServerLogDirect(_ server: WebServer) {
        let path = serverLogPath(server.id)
        guard FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc @MainActor private func startServer(_ sender: NSMenuItem) {
        guard let server = sender.representedObject as? WebServer else { return }
        startServerDirect(server)
    }

    @MainActor private func startServerDirect(_ server: WebServer) {
        guard let cwd = server.cwd,
              let command = server.startCommand else { return }
        guard serverActionsInProgress[server.id] == nil else { return }
        setWatchdogSuppressed("local:\(server.id)", false)
        serverActionsInProgress[server.id] = "Starting…"
        serverActionMessages[server.id] = nil
        refreshPopoverContentIfShown()
        registry.upsert(server)
        let activityStore = activityStore
        serverWorker.async { [weak self] in
            launchServer(command: command, cwd: cwd, id: server.id)
            activityStore.record(category: "local-server", title: "Started \(server.name)", detail: command, level: .success)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                self?.serverActionsInProgress.removeValue(forKey: server.id)
                self?.refresh(updateOpenPopover: true)
            }
        }
    }

    @objc @MainActor private func stopServer(_ sender: NSMenuItem) {
        guard let server = sender.representedObject as? WebServer else { return }
        stopServerDirect(server)
    }

    @MainActor private func stopServerDirect(_ server: WebServer) {
        guard server.isRunning else { return }
        guard serverActionsInProgress[server.id] == nil else { return }
        setWatchdogSuppressed("local:\(server.id)", true)
        serverActionsInProgress[server.id] = "Stopping…"
        serverActionMessages[server.id] = nil
        refreshPopoverContentIfShown()
        registry.upsert(server)
        let activityStore = activityStore
        serverWorker.async { [weak self] in
            let result = terminateWebServer(server)
            activityStore.record(category: "local-server", title: result.stopped ? "Stopped \(server.name)" : "Failed to stop \(server.name)", detail: result.detail, level: result.stopped ? .success : .error)
            DispatchQueue.main.async {
                self?.serverActionsInProgress.removeValue(forKey: server.id)
                self?.serverActionMessages[server.id] = result.detail
                self?.refresh(updateOpenPopover: true)
            }
        }
    }

    @objc @MainActor private func removeServer(_ sender: NSMenuItem) {
        guard let server = sender.representedObject as? WebServer else { return }
        removeServerDirect(server)
    }

    @MainActor private func removeServerDirect(_ server: WebServer) {
        guard serverActionsInProgress[server.id] == nil else { return }
        serverActionsInProgress[server.id] = server.isRunning ? "Stopping & removing…" : "Removing…"
        serverActionMessages[server.id] = nil
        refreshPopoverContentIfShown()

        let activityStore = activityStore
        serverWorker.async { [weak self] in
            let result = server.isRunning
                ? terminateWebServer(server)
                : ServerTerminationResult(stopped: true, forced: false, detail: "Removed")

            if result.stopped {
                self?.registry.remove(id: server.id)
            }
            activityStore.record(category: "local-server", title: result.stopped ? "Removed \(server.name)" : "Failed to remove \(server.name)", detail: result.detail, level: result.stopped ? .success : .error)

            DispatchQueue.main.async {
                guard let self else { return }
                self.serverActionsInProgress.removeValue(forKey: server.id)
                if result.stopped {
                    self.serverActionMessages.removeValue(forKey: server.id)
                    self.snapshot.servers.removeAll { $0.id == server.id }
                    self.refreshPopoverContentIfShown()
                } else {
                    self.serverActionMessages[server.id] = result.detail
                }
                self.refresh(updateOpenPopover: true)
            }
        }
    }

    @objc @MainActor private func stopAllServers() {
        stopAllServersDirect()
    }

    @MainActor private func stopAllServersDirect() {
        let servers = snapshot.servers.filter { $0.isRunning && serverActionsInProgress[$0.id] == nil }
        guard !servers.isEmpty else { return }

        for server in servers {
            setWatchdogSuppressed("local:\(server.id)", true)
            serverActionsInProgress[server.id] = "Stopping…"
            serverActionMessages[server.id] = nil
            registry.upsert(server)
        }
        refreshPopoverContentIfShown()

        let group = DispatchGroup()
        let activityStore = activityStore
        for server in servers {
            group.enter()
            serverWorker.async { [weak self] in
                let result = terminateWebServer(server)
                activityStore.record(category: "local-server", title: result.stopped ? "Stopped \(server.name)" : "Failed to stop \(server.name)", detail: result.detail, level: result.stopped ? .success : .error)
                DispatchQueue.main.async {
                    self?.serverActionsInProgress.removeValue(forKey: server.id)
                    self?.serverActionMessages[server.id] = result.detail
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.refresh(updateOpenPopover: true)
        }
    }

    @objc @MainActor private func clearStoppedServers() {
        clearStoppedServersDirect()
    }

    @MainActor private func clearStoppedServersDirect() {
        let managedIDs = Set(config.localServices.map(\.id))
        let stoppedIDs = snapshot.servers.filter { !$0.isRunning && !managedIDs.contains($0.id) }.map(\.id)
        guard !stoppedIDs.isEmpty else { return }
        registry.remove(ids: stoppedIDs)
        activityStore.record(category: "local-server", title: "Cleared \(stoppedIDs.count) stopped service\(stoppedIDs.count == 1 ? "" : "s")", detail: "Removed stopped entries from the dashboard", level: .info)
        snapshot.servers.removeAll { stoppedIDs.contains($0.id) }
        for id in stoppedIDs {
            serverActionsInProgress.removeValue(forKey: id)
            serverActionMessages.removeValue(forKey: id)
        }
        refreshPopoverContentIfShown()
        refresh(updateOpenPopover: true)
    }

    @MainActor private func startStackDirect(_ stack: ProjectStackConfig) {
        guard !stackActionsInProgress.contains(stack.id) else { return }
        stackActionsInProgress.insert(stack.id)
        for id in stack.localServiceIDs { setWatchdogSuppressed("local:\(id)", false) }
        for id in stack.remoteServiceIDs { setWatchdogSuppressed("remote:\(id)", false) }
        refreshPopoverContentIfShown()
        let localConfigs = config.localServices.filter { stack.localServiceIDs.contains($0.id) }
        let remoteConfigs = config.remoteServices.filter { stack.remoteServiceIDs.contains($0.id) }
        let currentServers = snapshot.servers
        let currentRemote = snapshot.remoteServices
        let remoteController = remoteServiceController
        let activityStore = activityStore

        operationsWorker.async { [weak self] in
            for service in localConfigs {
                guard currentServers.first(where: { $0.id == service.id })?.isRunning != true else { continue }
                launchServer(command: service.startCommand, cwd: service.cwd, id: service.id)
                activityStore.record(category: "stack", title: "Started \(service.name)", detail: "Started from stack \(stack.name)", level: .success)
            }
            for service in remoteConfigs {
                guard currentRemote.first(where: { $0.config.id == service.id })?.running != true else { continue }
                let result = remoteController.start(service)
                activityStore.record(category: "stack", title: result.succeeded ? "Started \(service.name)" : "Failed to start \(service.name)", detail: result.detail, level: result.succeeded ? .success : .error)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                self?.stackActionsInProgress.remove(stack.id)
                self?.refresh(updateOpenPopover: true)
            }
        }
    }

    @MainActor private func stopStackDirect(_ stack: ProjectStackConfig) {
        guard !stackActionsInProgress.contains(stack.id) else { return }
        stackActionsInProgress.insert(stack.id)
        for id in stack.localServiceIDs { setWatchdogSuppressed("local:\(id)", true) }
        for id in stack.remoteServiceIDs { setWatchdogSuppressed("remote:\(id)", true) }
        refreshPopoverContentIfShown()
        let localServers = snapshot.servers.filter { stack.localServiceIDs.contains($0.id) && $0.isRunning }
        let remoteStatuses = snapshot.remoteServices.filter { stack.remoteServiceIDs.contains($0.config.id) && $0.running }
        let remoteController = remoteServiceController
        let activityStore = activityStore

        operationsWorker.async { [weak self] in
            for server in localServers {
                let result = terminateWebServer(server)
                activityStore.record(category: "stack", title: result.stopped ? "Stopped \(server.name)" : "Failed to stop \(server.name)", detail: result.detail, level: result.stopped ? .success : .error)
            }
            for status in remoteStatuses {
                let result = remoteController.stop(status.config)
                activityStore.record(category: "stack", title: result.succeeded ? "Stopped \(status.config.name)" : "Failed to stop \(status.config.name)", detail: result.detail, level: result.succeeded ? .success : .error)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self?.stackActionsInProgress.remove(stack.id)
                self?.refresh(updateOpenPopover: true)
            }
        }
    }

    @MainActor private func performRemoteServiceAction(_ command: RemoteServiceCommand, status: RemoteServiceStatus) {
        let id = status.config.id
        guard remoteServiceActionsInProgress[id] == nil else { return }
        setWatchdogSuppressed("remote:\(id)", command == .stop)
        let actionTitle: String
        switch command {
        case .start: actionTitle = "Starting…"
        case .stop: actionTitle = "Stopping…"
        case .restart: actionTitle = "Restarting…"
        }
        remoteServiceActionsInProgress[id] = actionTitle
        remoteServiceActionMessages[id] = nil
        refreshPopoverContentIfShown()
        let controller = remoteServiceController
        let service = status.config
        let activityStore = activityStore

        operationsWorker.async { [weak self] in
            let result: RemoteServiceActionResult
            switch command {
            case .start: result = controller.start(service)
            case .stop: result = controller.stop(service)
            case .restart: result = controller.restart(service)
            }
            let verb: String
            let pastVerb: String
            switch command {
            case .start: verb = "Start"; pastVerb = "Started"
            case .stop: verb = "Stop"; pastVerb = "Stopped"
            case .restart: verb = "Restart"; pastVerb = "Restarted"
            }
            activityStore.record(
                category: "remote-service",
                title: result.succeeded ? "\(pastVerb) \(service.name)" : "\(verb) failed for \(service.name)",
                detail: result.detail,
                level: result.succeeded ? .success : .error
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self?.remoteServiceActionsInProgress.removeValue(forKey: id)
                self?.remoteServiceActionMessages[id] = result.detail
                self?.refresh(updateOpenPopover: true)
            }
        }
    }

    @MainActor private func openRemoteServiceLogs(_ status: RemoteServiceStatus) {
        let id = status.config.id
        guard remoteServiceActionsInProgress[id] == nil else { return }
        remoteServiceActionsInProgress[id] = "Loading logs…"
        refreshPopoverContentIfShown()
        let controller = remoteServiceController
        operationsWorker.async { [weak self] in
            let result = controller.fetchLogs(status.config)
            var localPath: String?
            if result.succeeded {
                let directory = homePath(".codex-menu-bar/remote-logs")
                ensureDirectory(directory)
                let path = "\(directory)/\(id.replacingOccurrences(of: "/", with: "_")).log"
                try? result.detail.write(toFile: path, atomically: true, encoding: .utf8)
                localPath = path
            }
            DispatchQueue.main.async {
                self?.remoteServiceActionsInProgress.removeValue(forKey: id)
                self?.remoteServiceActionMessages[id] = result.succeeded ? "Opened latest remote logs" : result.detail
                if let localPath {
                    NSWorkspace.shared.open(URL(fileURLWithPath: localPath))
                }
                self?.refreshPopoverContentIfShown()
            }
        }
    }

    @MainActor private func setPublishModeDirect(_ mode: PublishMode, status: PublishStatus) {
        let id = status.config.id
        guard !publishActionsInProgress.contains(id) else { return }
        if mode != .off {
            let alert = NSAlert()
            alert.alertStyle = mode == .funnel ? .critical : .warning
            alert.messageText = mode == .funnel ? "Expose \(status.config.name) to the public internet?" : "Share \(status.config.name) with your tailnet?"
            alert.informativeText = mode == .funnel
                ? "Tailscale Funnel makes port \(status.config.port) reachable by anyone on the internet. Only continue when the local service is safe for public access."
                : "Tailscale Serve makes port \(status.config.port) reachable only to identities allowed by your tailnet access rules."
            alert.addButton(withTitle: mode == .funnel ? "Expose Publicly" : "Share Privately")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        publishActionsInProgress.insert(id)
        publishActionMessages[id] = nil
        refreshPopoverContentIfShown()
        let controller = publishController
        let target = status.config
        let activityStore = activityStore
        operationsWorker.async { [weak self] in
            let result = controller.setMode(mode, target: target)
            activityStore.record(
                category: "sharing",
                title: result.succeeded ? "Sharing changed for \(target.name)" : "Sharing change failed for \(target.name)",
                detail: result.detail,
                level: result.succeeded ? (mode == .funnel ? .warning : .success) : .error
            )
            DispatchQueue.main.async {
                self?.publishActionsInProgress.remove(id)
                self?.publishActionMessages[id] = result.detail
                self?.refresh(updateOpenPopover: true)
            }
        }
    }

    @MainActor private func cycleLocalWatchdog(id: String) {
        guard let index = config.localServices.firstIndex(where: { $0.id == id }) else { return }
        config.localServices[index].watchdog = nextWatchdogPolicy(config.localServices[index].watchdog)
        let policy = config.localServices[index].watchdog
        config.save()
        if policy.enabled { setWatchdogSuppressed("local:\(id)", false) }
        activityStore.record(category: "watchdog", title: "Updated \(config.localServices[index].name) watchdog", detail: watchdogButtonTitle(policy), level: .info)
        refreshPopoverContentIfShown()
    }

    @MainActor private func cycleRemoteWatchdog(id: String) {
        guard let index = config.remoteServices.firstIndex(where: { $0.id == id }) else { return }
        config.remoteServices[index].watchdog = nextWatchdogPolicy(config.remoteServices[index].watchdog)
        let policy = config.remoteServices[index].watchdog
        config.save()
        if policy.enabled { setWatchdogSuppressed("remote:\(id)", false) }
        remoteServiceController = RemoteServiceController(config: config)
        if let snapshotIndex = snapshot.remoteServices.firstIndex(where: { $0.config.id == id }) {
            snapshot.remoteServices[snapshotIndex].config.watchdog = policy
        }
        activityStore.record(category: "watchdog", title: "Updated \(config.remoteServices[index].name) watchdog", detail: watchdogButtonTitle(policy), level: .info)
        refreshPopoverContentIfShown()
    }

    private func nextWatchdogPolicy(_ policy: WatchdogPolicyConfig) -> WatchdogPolicyConfig {
        if !policy.enabled {
            return WatchdogPolicyConfig(enabled: true, autoRestart: false, notifications: true)
        }
        if !policy.autoRestart {
            return WatchdogPolicyConfig(enabled: true, autoRestart: true, notifications: true)
        }
        return WatchdogPolicyConfig()
    }

    @objc @MainActor private func runWatchdogCheck() {
        let enabled = config.localServices.contains { $0.watchdog.enabled }
            || config.remoteServices.contains { $0.watchdog.enabled }
        guard enabled, !isRefreshing else { return }
        refresh(updateOpenPopover: popover?.isShown == true)
    }

    @MainActor private func evaluateWatchdogs(using next: DashboardSnapshot) {
        var activityChanged = false
        for service in config.localServices where service.watchdog.enabled {
            let key = "local:\(service.id)"
            guard !watchdogSuppressedIDs.contains(key) else { continue }
            let healthy = next.servers.first(where: { $0.id == service.id })?.isRunning == true
            activityChanged = handleWatchdogTransition(
                key: key,
                name: service.name,
                healthy: healthy,
                policy: service.watchdog,
                restart: { [weak self] in
                    guard let server = self?.snapshot.servers.first(where: { $0.id == service.id }) else { return }
                    self?.startServerDirect(server)
                }
            ) || activityChanged
        }
        for status in next.remoteServices where status.config.watchdog.enabled {
            let service = status.config
            let key = "remote:\(service.id)"
            guard !watchdogSuppressedIDs.contains(key) else { continue }
            let healthy = status.running && status.healthOK != false
            activityChanged = handleWatchdogTransition(
                key: key,
                name: service.name,
                healthy: healthy,
                policy: service.watchdog,
                restart: { [weak self] in self?.performRemoteServiceAction(.restart, status: status) }
            ) || activityChanged
        }
        if activityChanged {
            snapshot.activityEvents = activityStore.load()
        }
    }

    @MainActor private func handleWatchdogTransition(
        key: String,
        name: String,
        healthy: Bool,
        policy: WatchdogPolicyConfig,
        restart: () -> Void
    ) -> Bool {
        let previous = watchdogLastHealthy[key]
        watchdogLastHealthy[key] = healthy
        guard previous != healthy else { return false }
        if healthy {
            if previous == false {
                activityStore.record(category: "watchdog", title: "\(name) recovered", detail: "The service is healthy again", level: .success)
                if policy.notifications {
                    notificationController.notify(title: "\(name) recovered", body: "The service is healthy again.")
                }
                return true
            }
            return false
        }

        activityStore.record(category: "watchdog", title: "\(name) is unhealthy", detail: "The watchdog detected a stopped process or failed health check", level: .error)
        if policy.notifications {
            notificationController.notify(title: "\(name) is unhealthy", body: "The process stopped or its health check failed.")
        }
        if policy.autoRestart {
            let lastRestart = watchdogLastRestartAt[key] ?? .distantPast
            if Date().timeIntervalSince(lastRestart) >= 60 {
                watchdogLastRestartAt[key] = Date()
                activityStore.record(category: "watchdog", title: "Auto-restarting \(name)", detail: "Watchdog recovery started", level: .warning)
                restart()
            }
        }
        return true
    }

    @MainActor private func clearActivityDirect() {
        activityStore.clear()
        snapshot.activityEvents = []
        refreshPopoverContentIfShown()
    }

    @objc @MainActor private func openRegistry() {
        let path = homePath(".codex-menu-bar/servers.json")
        if !FileManager.default.fileExists(atPath: path) {
            ServerRegistry().save(ServerRegistryData())
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc @MainActor private func openSettings() {
        openSettingsDirect()
    }

    @MainActor private func openSettingsDirect() {
        if let controller = settingsWindowController, controller.window?.isVisible == true {
            NSApp.activate(ignoringOtherApps: true)
            controller.showWindow(nil)
            return
        }
        let controller = SettingsWindowController(
            branding: config.branding,
            configPath: AppConfig.filePath,
            onSave: { [weak self] branding in
                guard let self else { return }
                self.config.branding = branding
                self.config.save()
                self.configureStatusItem()
                self.activityStore.record(
                    category: "settings",
                    title: "Updated dashboard appearance",
                    detail: "Saved local branding preferences",
                    level: .success
                )
                if self.currentMenu != nil { self.rebuildMenu() }
                self.refreshPopoverContentIfShown()
            },
            onClose: { [weak self] in
                self?.settingsWindowController = nil
            }
        )
        settingsWindowController = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        runtimeLog("settings window opened")
    }

    @objc @MainActor private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

func serverLogPath(_ id: String) -> String {
    let safeID = id.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "|", with: "_")
    return homePath(".codex-menu-bar/logs/\(safeID).log")
}

func launchServer(command: String, cwd: String, id: String) {
    let logsDir = homePath(".codex-menu-bar/logs")
    ensureDirectory(logsDir)
    let logPath = serverLogPath(id)
    FileManager.default.createFile(atPath: logPath, contents: nil)
    guard let log = FileHandle(forWritingAtPath: logPath) else { return }
    _ = try? log.seekToEnd()

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-lc", "exec \(command)"]
    process.currentDirectoryURL = URL(fileURLWithPath: cwd)
    process.standardOutput = log
    process.standardError = log
    try? process.run()
}

func printSnapshotAndExit() -> Never {
    let config = AppConfig.load()
    let snapshot = DashboardSnapshot(
        servers: ServerCollector(config: config).collect(),
        remoteConnections: RemoteProjectCollector(config: config).collect(),
        remoteServices: RemoteServiceController(config: config).collect(),
        publishStatuses: TailscalePublishController(config: config).collect(),
        activityEvents: ActivityStore().load(),
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
        "branding": [
            "name": config.branding.name,
            "subtitle": config.branding.subtitle,
            "customIconConfigured": config.branding.iconPath != nil
        ],
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
                "url": jsonValue(server.urlString),
                "cpuPercent": jsonValue(server.cpuPercent),
                "memoryBytes": jsonValue(server.memoryBytes),
                "uptime": jsonValue(server.uptimeText),
                "listenerCount": server.listenerCount,
                "portConflict": server.portConflict
            ]
        },
        "remoteServices": snapshot.remoteServices.map { service in
            [
                "id": service.config.id,
                "name": service.config.name,
                "target": service.config.target,
                "port": service.config.port,
                "loaded": service.loaded,
                "running": service.running,
                "pid": jsonValue(service.pid),
                "healthOK": jsonValue(service.healthOK),
                "cpuPercent": jsonValue(service.cpuPercent),
                "memoryBytes": jsonValue(service.memoryBytes),
                "uptime": jsonValue(service.uptimeText),
                "detail": service.detail
            ]
        },
        "publishing": snapshot.publishStatuses.map { status in
            [
                "id": status.config.id,
                "name": status.config.name,
                "port": status.config.port,
                "mode": status.mode.rawValue,
                "url": jsonValue(status.url),
                "detail": status.detail
            ]
        },
        "activity": snapshot.activityEvents.map { event in
            [
                "id": event.id.uuidString,
                "date": formatter.string(from: event.date),
                "category": event.category,
                "title": event.title,
                "detail": event.detail,
                "level": event.level.rawValue
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

func runRemoteServiceActionAndExit() -> Never {
    guard let flagIndex = CommandLine.arguments.firstIndex(of: "--remote-service-action"),
          CommandLine.arguments.count > flagIndex + 2 else {
        fputs("Usage: --remote-service-action <service-id> <start|stop|restart>\n", stderr)
        exit(64)
    }
    let id = CommandLine.arguments[flagIndex + 1]
    let action = CommandLine.arguments[flagIndex + 2]
    let config = AppConfig.load()
    guard let service = config.remoteServices.first(where: { $0.id == id }) else {
        fputs("Unknown remote service: \(id)\n", stderr)
        exit(66)
    }
    let controller = RemoteServiceController(config: config)
    let result: RemoteServiceActionResult
    switch action {
    case "start": result = controller.start(service)
    case "stop": result = controller.stop(service)
    case "restart": result = controller.restart(service)
    default:
        fputs("Unknown action: \(action)\n", stderr)
        exit(64)
    }
    print(result.detail)
    exit(result.succeeded ? 0 : 1)
}

func runLocalServiceActionAndExit() -> Never {
    guard let flagIndex = CommandLine.arguments.firstIndex(of: "--local-service-action"),
          CommandLine.arguments.count > flagIndex + 2 else {
        fputs("Usage: --local-service-action <service-id> <start|stop>\n", stderr)
        exit(64)
    }
    let id = CommandLine.arguments[flagIndex + 1]
    let action = CommandLine.arguments[flagIndex + 2]
    let config = AppConfig.load()
    guard let service = config.localServices.first(where: { $0.id == id }) else {
        fputs("Unknown local service: \(id)\n", stderr)
        exit(66)
    }
    let server = ServerCollector(config: config).collect().first { $0.id == id }

    switch action {
    case "start":
        if server?.isRunning == true {
            print("Already running: \(service.name)")
        } else {
            launchServer(command: service.startCommand, cwd: service.cwd, id: service.id)
            print("Started \(service.name)")
        }
        exit(0)
    case "stop":
        guard let server, server.isRunning else {
            print("Already stopped: \(service.name)")
            exit(0)
        }
        let result = terminateWebServer(server)
        print(result.detail)
        exit(result.stopped ? 0 : 1)
    default:
        fputs("Unknown action: \(action)\n", stderr)
        exit(64)
    }
}

if CommandLine.arguments.contains("--remote-service-action") {
    runRemoteServiceActionAndExit()
}

if CommandLine.arguments.contains("--local-service-action") {
    runLocalServiceActionAndExit()
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
