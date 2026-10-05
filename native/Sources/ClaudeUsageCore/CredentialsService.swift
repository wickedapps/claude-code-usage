import Foundation

/// Claude Code's stored OAuth login. The app reads it and never refreshes it.
struct StoredCredentials: Equatable {
    var token: String
    var expiresAt: Date?
    var subscriptionType: String?
    var rateLimitTier: String?

    func isExpired(at now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }
}

extension StoredCredentials: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String {
        "StoredCredentials(token: <redacted>, expiresAt: \(String(describing: expiresAt)), subscriptionType: \(subscriptionType ?? "nil"))"
    }

    var debugDescription: String { description }
}

enum CredentialLoad: Equatable {
    case found(StoredCredentials)
    case missing
}

enum CredentialsService {
    static let tokenEnvironment = "CLAUDE_OAUTH_ACCESS_TOKEN"
    static let keychainService = "Claude Code-credentials"
    static let keychainExecutable = "/usr/bin/security"
    static let keychainArguments = ["find-generic-password", "-s", keychainService, "-w"]
    static let keychainTimeout: TimeInterval = 15
    static let profileFile = ".claude.json"
    static let credentialFiles = [".claude/.credentials.json", ".claude/credentials.json"]
    private static let tokenNests = ["claudeAiOauth", "claude_ai_oauth", "oauth"]

    /// Environment override, then the login keychain, then the credential files.
    /// An empty environment value does not count. The token is not refreshed.
    static func load(
        environment: [String: String],
        home: String?,
        keychainJSON: () -> String?,
        readFile: (String) -> String?
    ) -> CredentialLoad {
        if let raw = environment[tokenEnvironment] {
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                return .found(StoredCredentials(
                    token: token,
                    expiresAt: nil,
                    subscriptionType: nil,
                    rateLimitTier: nil
                ))
            }
        }

        if let text = keychainJSON(), let credentials = credentials(fromJSONText: text) {
            return .found(credentials)
        }

        if let home {
            for relative in credentialFiles {
                let path = pathJoin(home, relative)
                if let text = readFile(path), let credentials = credentials(fromJSONText: text) {
                    return .found(credentials)
                }
            }
        }
        return .missing
    }

    static func loadFromLiveSources() -> CredentialLoad {
        let environment = ProcessInfo.processInfo.environment
        return load(
            environment: environment,
            home: environment["HOME"],
            keychainJSON: liveKeychainJSON,
            readFile: readUTF8File
        )
    }

    static func planLabel(credentials: CredentialLoad, seatTier: String?) -> String? {
        guard case .found(let credentials) = credentials else { return nil }
        return AccountService.subscriptionLabel(
            subscriptionType: credentials.subscriptionType,
            rateLimitTier: credentials.rateLimitTier,
            seatTier: seatTier
        )
    }

    static func liveSeatTier() -> String? {
        seatTier(home: ProcessInfo.processInfo.environment["HOME"], readFile: readUTF8File)
    }

    static func seatTier(home: String?, readFile: (String) -> String?) -> String? {
        guard let home else { return nil }
        guard let text = readFile(pathJoin(home, profileFile)) else { return nil }
        guard let data = text.data(using: .utf8) else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let account = root["oauthAccount"] as? [String: Any] else { return nil }
        return account["seatTier"] as? String
    }

    /// `security` prints the keychain password on stdout and errors on stderr.
    /// Stdout is parsed and never logged. A non-zero exit, a timeout, or
    /// invalid JSON is a miss, and the file fallback runs next.
    static func liveKeychainJSON() -> String? {
        guard let data = ProcessRunner.run(
            executable: keychainExecutable,
            arguments: keychainArguments,
            timeout: keychainTimeout,
            requireSuccess: true
        ) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func credentials(fromJSONText text: String) -> StoredCredentials? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else { return nil }
        guard let value = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return credentials(in: value)
    }

    /// The token key has moved between Claude Code versions. Try each nesting,
    /// then the top level. Expiry and plan come from the object that held the token.
    static func credentials(in value: Any) -> StoredCredentials? {
        guard let object = value as? [String: Any] else { return nil }
        var candidates: [Any] = []
        for key in tokenNests {
            if let nested = object[key], !(nested is NSNull) {
                candidates.append(nested)
            }
        }
        candidates.append(object)
        for candidate in candidates {
            if let credentials = credentials(fromCandidate: candidate) {
                return credentials
            }
        }
        return nil
    }

    private static func credentials(fromCandidate candidate: Any) -> StoredCredentials? {
        guard let object = candidate as? [String: Any] else { return nil }
        guard let raw = object["accessToken"] as? String else { return nil }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty { return nil }
        let expiresAt = JSONValues.int64(object["expiresAt"]).map { millis in
            Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
        }
        return StoredCredentials(
            token: token,
            expiresAt: expiresAt,
            subscriptionType: object["subscriptionType"] as? String,
            rateLimitTier: object["rateLimitTier"] as? String
        )
    }

    private static func readUTF8File(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum JSONValues {
    static func double(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

    /// Integers only; fractional or out-of-range values are rejected.
    static func int64(_ value: Any?) -> Int64? {
        guard let number = double(value) else { return nil }
        guard number.rounded(.towardZero) == number else { return nil }
        return Int64(exactly: number)
    }

    /// Epoch seconds. Fractional values truncate toward zero.
    static func epochSeconds(_ value: Any?) -> Int64? {
        guard let number = double(value) else { return nil }
        let truncated = number.rounded(.towardZero)
        return Int64(exactly: truncated)
    }
}
