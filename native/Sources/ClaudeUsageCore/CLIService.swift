import Darwin
import Foundation

/// Finds `claude` and the auth variables a terminal would see.
///
/// Finder and login-item launches inherit launchd's PATH. `zsh -l` reads
/// `.zprofile` and skips `.zshrc`, which is where the native installer, npm,
/// bun, pnpm, and mise add themselves. The PATH and auth variables come from
/// an interactive login shell, with the usual install directories behind that.
enum CLIService {
    static let binaryName = "claude"
    static let fallbackShell = "/bin/zsh"
    static let pathStart = "__CLAUDE_USAGE_PATH_START__"
    static let pathEnd = "__CLAUDE_USAGE_PATH_END__"
    static let authNames = [
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
        "CLAUDE_CODE_OAUTH_TOKEN",
        "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_VERTEX",
        "CLAUDE_CODE_USE_FOUNDRY",
        "CLAUDE_CONFIG_DIR",
    ]
    static let gatewayTokenName = "ANTHROPIC_AUTH_TOKEN"
    static let setupTokenName = "CLAUDE_CODE_OAUTH_TOKEN"
    static let shellTimeout: TimeInterval = 5
    static let launchctlTimeout: TimeInterval = 2
    static let versionTimeout: TimeInterval = 4
    static let authStatusTimeout: TimeInterval = 5
    static let authStatusArguments = ["auth", "status", "--json"]
    static let homeInstallDirs = [
        ".local/bin",
        ".claude/local",
        ".bun/bin",
        ".npm-global/bin",
        ".volta/bin",
        "Library/pnpm",
        ".local/share/pnpm",
        ".local/share/mise/shims",
        ".asdf/shims",
        ".yarn/bin",
    ]
    static let systemInstallDirs = ["/opt/homebrew/bin", "/usr/local/bin"]
    static let nvmVersionsDir = ".nvm/versions/node"

    /// Read once per process. A later install in one of the usual directories
    /// is still found by `installDirectories`.
    private static let cachedLoginEnv: LoginEnv = loadLoginEnv()

    static func locate() -> String? {
        locate(in: liveSearchDirectories())
    }

    static func locate(in directories: [String]) -> String? {
        for directory in directories {
            let path = pathJoin(directory, binaryName)
            if isExecutableFile(path) {
                return path
            }
        }
        return nil
    }

    /// First whitespace-separated word that starts with a digit, with leading
    /// and trailing non-version characters removed.
    static func version(from text: String) -> String? {
        for part in text.split(whereSeparator: { $0.isWhitespace }) {
            guard let first = part.first, first.isASCII, first.isNumber else { continue }
            let trimmed = trimVersion(String(part))
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private static func trimVersion(_ value: String) -> String {
        let characters = Array(value)
        var start = 0
        var end = characters.count
        while start < end, isVersionTrim(characters[start]) { start += 1 }
        while end > start, isVersionTrim(characters[end - 1]) { end -= 1 }
        return String(characters[start..<end])
    }

    private static func isVersionTrim(_ character: Character) -> Bool {
        let isDigit = character.isASCII && character.isNumber
        return !isDigit && character != "."
    }

    static func version(binary: String) -> String? {
        guard let data = ProcessRunner.run(
            executable: binary,
            arguments: ["--version"],
            environment: childEnvironment(path: searchPath()),
            timeout: versionTimeout
        ), let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return version(from: text)
    }

    /// `claude auth status --json` with the login shell's auth variables.
    /// Signed out, the CLI still prints JSON and exits 1, so the exit code is ignored.
    /// The captured text is parsed and never logged.
    static func authStatus(binary: String) -> [String: Any]? {
        guard let data = ProcessRunner.run(
            executable: binary,
            arguments: authStatusArguments,
            environment: childEnvironment(path: searchPath(), auth: cachedLoginEnv.auth),
            timeout: authStatusTimeout
        ) else {
            return nil
        }
        return jsonObject(from: data)
    }

    static func billing(binary: String) -> ApiBilling? {
        guard let status = authStatus(binary: binary) else { return nil }
        return AccountService.apiBilling(status: status, gatewayToken: hasGatewayToken())
    }

    static func hasGatewayToken() -> Bool {
        hasGatewayToken(
            loginNames: Set(cachedLoginEnv.auth.map(\.name)),
            processEnvironment: ProcessInfo.processInfo.environment
        )
    }

    /// A gateway bearer token and `claude setup-token` both show up as
    /// `oauth_token`. Only the variable that supplied the token tells them apart.
    static func hasGatewayToken(loginNames: Set<String>, processEnvironment: [String: String]) -> Bool {
        func isSet(_ name: String) -> Bool {
            loginNames.contains(name) || processEnvironment[name] != nil
        }
        return isSet(gatewayTokenName) && !isSet(setupTokenName)
    }

    static func liveTranscriptEnvironment() -> [String: String] {
        transcriptEnvironment(process: ProcessInfo.processInfo.environment, login: cachedLoginEnv)
    }

    /// Process environment plus the login shell's `CLAUDE_CONFIG_DIR` when it
    /// has one. Auth tokens stay out of the dictionary handed to transcript loading.
    static func transcriptEnvironment(process: [String: String], login: LoginEnv) -> [String: String] {
        var environment = process
        if let config = login.auth.first(where: { $0.name == "CLAUDE_CONFIG_DIR" })?.value {
            environment["CLAUDE_CONFIG_DIR"] = config
        }
        return environment
    }

    static func childEnvironment(
        path: String,
        auth: [AuthVariable] = [],
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        environment["PATH"] = path
        for variable in auth where authNames.contains(variable.name) {
            environment[variable.name] = variable.value
        }
        return environment
    }

    static func searchPath() -> String {
        joinSearchPath(liveSearchDirectories())
    }

    static func liveSearchDirectories() -> [String] {
        searchDirectories(
            shellPath: cachedLoginEnv.path,
            processPath: ProcessInfo.processInfo.environment["PATH"],
            home: ProcessInfo.processInfo.environment["HOME"],
            listChildren: { path in
                (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            }
        )
    }

    static func searchDirectories(
        shellPath: String?,
        processPath: String?,
        home: String?,
        listChildren: (String) -> [String]
    ) -> [String] {
        var directories: [String] = []
        if let shellPath {
            directories.append(contentsOf: splitPath(shellPath))
        }
        if let processPath {
            directories.append(contentsOf: splitPath(processPath))
        }
        directories.append(contentsOf: installDirectories(home: home, listChildren: listChildren))
        var seen = Set<String>()
        return directories.filter { directory in
            !directory.isEmpty && seen.insert(directory).inserted
        }
    }

    static func installDirectories(home: String?, listChildren: (String) -> [String]) -> [String] {
        var directories: [String] = []
        if let home {
            directories.append(contentsOf: homeInstallDirs.map { pathJoin(home, $0) })
            let versions = pathJoin(home, nvmVersionsDir)
            let bins = listChildren(versions).map { pathJoin(pathJoin(versions, $0), "bin") }
            directories.append(contentsOf: bins.sorted(by: >))
        }
        directories.append(contentsOf: systemInstallDirs)
        return directories
    }

    static func splitPath(_ path: String) -> [String] {
        path.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    }

    /// `join_paths` fails when any component contains the separator. An empty
    /// PATH is what the child gets in that case.
    static func joinSearchPath(_ directories: [String]) -> String {
        if directories.contains(where: { $0.contains(":") }) {
            return ""
        }
        return directories.joined(separator: ":")
    }

    static func isExecutableFile(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0 else { return false }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return false }
        return (info.st_mode & mode_t(0o111)) != 0
    }

    static func printEnvCommand() -> String {
        let names = authNames.joined(separator: "|")
        return "printf '%s\\n' '\(pathStart)'; printenv PATH || true; env | grep -E '^(\(names))=' || true; printf '%s\\n' '\(pathEnd)'"
    }

    static func parseMarkedEnv(_ text: String) -> LoginEnv? {
        guard let start = text.range(of: pathStart) else { return nil }
        let afterStart = text[start.upperBound...]
        guard let end = afterStart.range(of: pathEnd) else { return nil }
        let body = afterStart[..<end.lowerBound]
        var env = LoginEnv(path: nil, auth: [])
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if let separator = trimmed.firstIndex(of: "=") {
                let name = String(trimmed[..<separator])
                if authNames.contains(name) {
                    let value = String(trimmed[trimmed.index(after: separator)...])
                    env.auth.append(AuthVariable(name: name, value: value))
                    continue
                }
            }
            if env.path == nil {
                env.path = trimmed
            }
        }
        if env.path == nil && env.auth.isEmpty {
            return nil
        }
        return env
    }

    private static func loadLoginEnv() -> LoginEnv {
        var env = shellEnv() ?? LoginEnv(path: nil, auth: [])
        if env.path == nil {
            env.path = launchctlPath()
        }
        return env
    }

    private static func shellEnv() -> LoginEnv? {
        let configured = ProcessInfo.processInfo.environment["SHELL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let shell = (configured?.isEmpty == false ? configured : nil) ?? fallbackShell
        guard let data = ProcessRunner.run(
            executable: shell,
            arguments: ["-ilc", printEnvCommand()],
            timeout: shellTimeout,
            untilMarker: pathEnd
        ), let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return parseMarkedEnv(text)
    }

    private static func launchctlPath() -> String? {
        guard let data = ProcessRunner.run(
            executable: "/bin/launchctl",
            arguments: ["getenv", "PATH"],
            timeout: launchctlTimeout
        ), let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private static func jsonObject(from data: Data) -> [String: Any]? {
        let trimmed = trimASCIIWhitespace(data)
        guard !trimmed.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: trimmed) as? [String: Any]
    }
}

struct AuthVariable: Equatable {
    var name: String
    var value: String
}

struct LoginEnv: Equatable {
    var path: String?
    var auth: [AuthVariable]
}

enum ProcessRunner {
    struct RunResult {
        var stdout: Data
        var exitCode: Int32
        var timedOut: Bool
        var pid: Int32
    }

    /// Runs `executable` and returns stdout. Nil when it cannot start, when it
    /// exceeds `timeout` before finishing, or when `requireSuccess` is set and
    /// the exit code is not zero. Stderr is drained and discarded. Nothing from
    /// either pipe is written to a log or an error string.
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval,
        untilMarker: String? = nil,
        maxCaptureBytes: Int = 1_048_576,
        requireSuccess: Bool = false
    ) -> Data? {
        guard let result = capture(
            executable: executable,
            arguments: arguments,
            environment: environment,
            timeout: timeout,
            untilMarker: untilMarker,
            maxCaptureBytes: maxCaptureBytes
        ) else {
            return nil
        }
        if result.timedOut {
            return nil
        }
        if requireSuccess && result.exitCode != 0 {
            return nil
        }
        return result.stdout
    }

    static func capture(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval,
        untilMarker: String? = nil,
        maxCaptureBytes: Int = 1_048_576
    ) -> RunResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        let capture = CaptureBox(marker: untilMarker, limit: maxCaptureBytes)

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            collect(stdoutHandle, into: capture)
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            discard(stderrHandle, capture: capture)
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForWriting.closeFile()
            stderrPipe.fileHandleForWriting.closeFile()
            group.wait()
            return nil
        }

        // The parent still holds the write ends. Close them so the readers see
        // EOF when the child exits, instead of blocking forever.
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()

        let pid = process.processIdentifier
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            if capture.hitMarker {
                break
            }
            if Date() >= deadline {
                timedOut = true
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < grace {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                kill(pid, SIGKILL)
            }
        }
        process.waitUntilExit()
        if group.wait(timeout: .now() + 0.1) == .timedOut {
            capture.stop()
            group.wait()
        }

        return RunResult(
            stdout: capture.contents,
            exitCode: process.terminationStatus,
            timedOut: timedOut,
            pid: pid
        )
    }

    private static func collect(_ handle: FileHandle, into capture: CaptureBox) {
        defer { handle.closeFile() }
        readAvailable(handle.fileDescriptor, shouldStop: { capture.hitMarker || capture.isStopped }) { capture.append($0) }
    }

    private static func discard(_ handle: FileHandle, capture: CaptureBox) {
        defer { handle.closeFile() }
        readAvailable(handle.fileDescriptor, shouldStop: { capture.isStopped }) { _ in }
    }

    /// `read` returns as soon as bytes are available. `FileHandle.readData(ofLength:)`
    /// can sit until the requested count fills or the pipe closes, which hides a
    /// short marker line until the timeout kills the process.
    private static func readAvailable(_ fd: Int32, shouldStop: () -> Bool, consume: (Data) -> Void) {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while !shouldStop() {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
            let available = Darwin.poll(&descriptor, 1, 100)
            if available == 0 { continue }
            if available < 0 { if errno == EINTR { continue }; break }
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                consume(Data(buffer.prefix(count)))
                continue
            }
            if count < 0 && errno == EINTR { continue }
            break
        }
    }
}

/// Keeps stdout only up to the marker line or the byte cap, while the caller
/// keeps reading so the pipe buffer cannot fill.
private final class CaptureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var markerHit = false
    private var stopped = false
    private let marker: Data?
    private let limit: Int

    init(marker: String?, limit: Int) {
        if let marker, !marker.isEmpty {
            self.marker = Data(marker.utf8)
        } else {
            self.marker = nil
        }
        self.limit = max(1, limit)
    }

    func stop() { lock.lock(); stopped = true; lock.unlock() }

    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    var hitMarker: Bool {
        lock.lock()
        defer { lock.unlock() }
        return markerHit
    }

    var contents: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !markerHit, data.count < limit else { return }
        let room = limit - data.count
        data.append(chunk.prefix(room))
        guard let marker, let range = data.range(of: marker) else { return }
        let tail = data[range.upperBound...]
        if let newline = tail.firstIndex(of: 0x0A) {
            data = Data(data[..<data.index(after: newline)])
            markerHit = true
        } else if data.count >= limit {
            markerHit = true
        }
    }
}

func pathJoin(_ base: String, _ relative: String) -> String {
    relative.split(separator: "/").reduce(URL(fileURLWithPath: base, isDirectory: true)) { url, part in
        url.appendingPathComponent(String(part))
    }.path
}

func trimASCIIWhitespace(_ data: Data) -> Data {
    let whitespace = Data([0x20, 0x09, 0x0A, 0x0D])
    var start = data.startIndex
    var end = data.endIndex
    while start < end, whitespace.contains(data[start]) {
        start += 1
    }
    while end > start, whitespace.contains(data[end - 1]) {
        end -= 1
    }
    return data[start..<end]
}
