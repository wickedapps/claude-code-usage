import XCTest
@testable import ClaudeUsageCore

/// Parsing and classification only. These tests do not start the login shell,
/// read the login keychain, or call the usage endpoint.
final class ServicesTests: XCTestCase {
    func testPathIsReadFromBetweenTheMarkers() {
        let text = "Last login: today\n__CLAUDE_USAGE_PATH_START__\n/a:/b\n__CLAUDE_USAGE_PATH_END__\n"
        XCTAssertEqual(
            CLIService.parseMarkedEnv(text),
            LoginEnv(path: "/a:/b", auth: [])
        )
    }

    func testAuthVariablesComeAfterThePath() {
        let text = """
        __CLAUDE_USAGE_PATH_START__
        /a:/b
        ANTHROPIC_API_KEY=sk-x=y
        CLAUDE_CODE_USE_BEDROCK=1
        __CLAUDE_USAGE_PATH_END__

        """
        let env = CLIService.parseMarkedEnv(text)
        XCTAssertEqual(env?.path, "/a:/b")
        XCTAssertEqual(env?.auth.map(\.name), ["ANTHROPIC_API_KEY", "CLAUDE_CODE_USE_BEDROCK"])
        XCTAssertEqual(env?.auth.map(\.value), ["sk-x=y", "1"])
    }

    func testRcNoiseWithoutMarkersIsNotAPath() {
        XCTAssertNil(CLIService.parseMarkedEnv("/usr/bin:/bin\n"))
        XCTAssertNil(CLIService.parseMarkedEnv("__CLAUDE_USAGE_PATH_START__\n__CLAUDE_USAGE_PATH_END__\n"))
    }

    func testShellCommandIsBracketedByTheMarkers() {
        let command = CLIService.printEnvCommand()
        XCTAssertTrue(command.contains(CLIService.pathStart))
        XCTAssertTrue(command.hasSuffix("'\(CLIService.pathEnd)'"))
        XCTAssertTrue(command.contains("ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN"))
        XCTAssertTrue(command.contains("printf '%s\\n'"))
        XCTAssertTrue(command.contains("printenv PATH || true"))
        XCTAssertFalse(command.contains("sk-"))
    }

    func testSearchDirectoriesPreferShellPathThenDedupe() {
        let home = "/Users/example"
        let directories = CLIService.searchDirectories(
            shellPath: "/a:/b:",
            processPath: "/b:/c",
            home: home,
            listChildren: { _ in ["v9", "v20", "v18"] }
        )
        XCTAssertEqual(Array(directories.prefix(3)), ["/a", "/b", "/c"])
        let nvm = directories.filter { $0.contains(".nvm/versions/node") }
        XCTAssertEqual(nvm, [
            pathJoin(pathJoin(pathJoin(home, ".nvm/versions/node"), "v9"), "bin"),
            pathJoin(pathJoin(pathJoin(home, ".nvm/versions/node"), "v20"), "bin"),
            pathJoin(pathJoin(pathJoin(home, ".nvm/versions/node"), "v18"), "bin"),
        ])
        XCTAssertEqual(Array(directories.suffix(2)), ["/opt/homebrew/bin", "/usr/local/bin"])
        XCTAssertEqual(Set(directories).count, directories.count)
    }

    func testJoinSearchPathFailsClosedWhenAComponentContainsTheSeparator() {
        XCTAssertEqual(CLIService.joinSearchPath(["/usr/bin", "/odd:/bin"]), "")
        XCTAssertEqual(CLIService.joinSearchPath(["/usr/bin", "/bin"]), "/usr/bin:/bin")
    }

    func testLocateSkipsDirectoriesAndNonExecutableFiles() throws {
        let root = temporaryDirectory()
        defer { remove(root) }
        let skipped = root.appendingPathComponent("skip", isDirectory: true)
        let chosen = root.appendingPathComponent("chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: skipped, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        let directoryNamedClaude = skipped.appendingPathComponent("claude", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryNamedClaude, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directoryNamedClaude.path)
        let plain = skipped.appendingPathComponent("claude-file")
        FileManager.default.createFile(atPath: plain.path, contents: Data("nope".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plain.path)
        let binary = chosen.appendingPathComponent("claude")
        FileManager.default.createFile(atPath: binary.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        XCTAssertFalse(CLIService.isExecutableFile(directoryNamedClaude.path))
        XCTAssertFalse(CLIService.isExecutableFile(plain.path))
        XCTAssertEqual(
            CLIService.locate(in: [skipped.path, chosen.path]),
            binary.path
        )
    }

    func testVersionParserTakesTheFirstNumericToken() {
        XCTAssertEqual(CLIService.version(from: "claude 2.1.80\n"), "2.1.80")
        XCTAssertEqual(CLIService.version(from: "1.2.3-dev extra"), "1.2.3")
        XCTAssertNil(CLIService.version(from: "v2.0"))
        XCTAssertEqual(CLIService.version(from: "2.0v"), "2.0")
        XCTAssertEqual(CLIService.version(from: "build 2.1.80,"), "2.1.80")
        XCTAssertNil(CLIService.version(from: "unknown"))
    }

    func testGatewayTokenRequiresAuthTokenWithoutSetupToken() {
        XCTAssertTrue(CLIService.hasGatewayToken(
            loginNames: ["ANTHROPIC_AUTH_TOKEN"],
            processEnvironment: [:]
        ))
        XCTAssertFalse(CLIService.hasGatewayToken(
            loginNames: ["ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"],
            processEnvironment: [:]
        ))
        XCTAssertTrue(CLIService.hasGatewayToken(
            loginNames: [],
            processEnvironment: ["ANTHROPIC_AUTH_TOKEN": ""]
        ))
        XCTAssertFalse(CLIService.hasGatewayToken(
            loginNames: ["ANTHROPIC_AUTH_TOKEN"],
            processEnvironment: ["CLAUDE_CODE_OAUTH_TOKEN": "setup"]
        ))
    }

    func testTranscriptEnvironmentKeepsConfigDirAndDropsTokens() {
        let login = LoginEnv(path: "/bin", auth: [
            AuthVariable(name: "CLAUDE_CONFIG_DIR", value: "/shell/config"),
            AuthVariable(name: "ANTHROPIC_API_KEY", value: "sk-secret"),
        ])
        let environment = CLIService.transcriptEnvironment(
            process: ["HOME": "/Users/me", "CLAUDE_CONFIG_DIR": "/process/config"],
            login: login
        )
        XCTAssertEqual(environment["CLAUDE_CONFIG_DIR"], "/shell/config")
        XCTAssertEqual(environment["HOME"], "/Users/me")
        XCTAssertNil(environment["ANTHROPIC_API_KEY"])

        let untouched = CLIService.transcriptEnvironment(
            process: ["CLAUDE_CONFIG_DIR": "/process/config"],
            login: LoginEnv(path: nil, auth: [])
        )
        XCTAssertEqual(untouched["CLAUDE_CONFIG_DIR"], "/process/config")
    }

    func testChildEnvironmentSetsPathAndKnownAuthOnly() {
        let environment = CLIService.childEnvironment(
            path: "/usr/bin",
            auth: [
                AuthVariable(name: "ANTHROPIC_API_KEY", value: "sk-secret"),
                AuthVariable(name: "OTHER", value: "nope"),
            ],
            base: ["HOME": "/Users/me"]
        )
        XCTAssertEqual(environment["PATH"], "/usr/bin")
        XCTAssertEqual(environment["HOME"], "/Users/me")
        XCTAssertEqual(environment["ANTHROPIC_API_KEY"], "sk-secret")
        XCTAssertNil(environment["OTHER"])
        XCTAssertEqual(CLIService.authStatusArguments, ["auth", "status", "--json"])
    }

    func testPlansReadTheWayClaudeNamesThem() {
        XCTAssertEqual(AccountService.planName(subscriptionType: "pro", rateLimitTier: nil, seatTier: nil), "Pro")
        XCTAssertEqual(
            AccountService.planName(subscriptionType: "max", rateLimitTier: "default_claude_max_20x", seatTier: nil),
            "Max 20x"
        )
        XCTAssertEqual(
            AccountService.planName(subscriptionType: "max", rateLimitTier: "default_claude_max_5x", seatTier: nil),
            "Max 5x"
        )
        XCTAssertEqual(AccountService.planName(subscriptionType: "max", rateLimitTier: nil, seatTier: nil), "Max")
        XCTAssertEqual(
            AccountService.planName(
                subscriptionType: "claude_max_subscription",
                rateLimitTier: "default_claude_max_20x",
                seatTier: nil
            ),
            "Max 20x"
        )
    }

    func testTeamAndEnterpriseTakeTheirSeatTier() {
        XCTAssertEqual(
            AccountService.planName(subscriptionType: "team", rateLimitTier: "default_raven", seatTier: "team_standard"),
            "Team Standard"
        )
        XCTAssertEqual(
            AccountService.planName(subscriptionType: "team", rateLimitTier: "default_raven", seatTier: nil),
            "Team"
        )
        XCTAssertEqual(
            AccountService.planName(subscriptionType: "enterprise", rateLimitTier: nil, seatTier: "something_else"),
            "Enterprise"
        )
    }

    func testUnknownOrMissingPlan() {
        XCTAssertEqual(
            AccountService.planName(subscriptionType: "student_plus", rateLimitTier: nil, seatTier: nil),
            "Student Plus"
        )
        XCTAssertNil(AccountService.planName(subscriptionType: nil, rateLimitTier: "default_claude_max_20x", seatTier: nil))
        XCTAssertNil(AccountService.planName(subscriptionType: "  ", rateLimitTier: nil, seatTier: nil))
    }

    func testBillingClassification() {
        XCTAssertNil(AccountService.apiBilling(status: [
            "loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty", "subscriptionType": "team",
        ], gatewayToken: false))

        XCTAssertEqual(AccountService.apiBilling(status: [
            "loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty",
            "apiKeySource": "ANTHROPIC_API_KEY", "subscriptionType": NSNull(),
        ], gatewayToken: false), .apiKey)
        XCTAssertNil(AccountService.apiBilling(status: ["apiKeySource": ""], gatewayToken: false))

        let providers: [(String, ApiBilling)] = [
            ("bedrock", .bedrock), ("vertex", .vertex), ("foundry", .foundry), ("someday", .otherProvider),
        ]
        for (provider, billing) in providers {
            XCTAssertEqual(AccountService.apiBilling(status: [
                "loggedIn": true, "authMethod": "third_party", "apiProvider": provider,
            ], gatewayToken: false), billing)
        }

        let oauth = ["loggedIn": true, "authMethod": "oauth_token", "apiProvider": "firstParty"] as [String: Any]
        XCTAssertEqual(AccountService.apiBilling(status: oauth, gatewayToken: true), .authToken)
        XCTAssertNil(AccountService.apiBilling(status: oauth, gatewayToken: false))
        XCTAssertNil(AccountService.apiBilling(status: [
            "loggedIn": false, "authMethod": "none", "apiProvider": "firstParty",
        ], gatewayToken: false))
    }

    func testAccountLabels() {
        XCTAssertEqual(
            AccountService.subscriptionLabel(subscriptionType: "max", rateLimitTier: "default_claude_max_20x", seatTier: nil),
            "Max 20x plan"
        )
        XCTAssertNil(AccountService.subscriptionLabel(subscriptionType: nil, rateLimitTier: nil, seatTier: nil))
        XCTAssertEqual(ApiBilling.bedrock.accountLabel, "Pay per token · Amazon Bedrock")
        XCTAssertEqual(ApiBilling.apiKey.phrase, "an API key")
        XCTAssertEqual(ApiBilling.authToken.name, "API auth token")
    }

    func testStoredLoginCarriesExpiryAndPlan() throws {
        let text = """
        {"claudeAiOauth":{"accessToken":" token ","expiresAt":1790153332424,"subscriptionType":"max","rateLimitTier":"default_claude_max_20x"}}
        """
        let credentials = try XCTUnwrap(CredentialsService.credentials(fromJSONText: text))
        XCTAssertEqual(credentials.token, "token")
        XCTAssertEqual(credentials.subscriptionType, "max")
        XCTAssertEqual(credentials.rateLimitTier, "default_claude_max_20x")
        let expiresAt = try XCTUnwrap(credentials.expiresAt)
        XCTAssertEqual(expiresAt.timeIntervalSince1970, 1_790_153_332.424, accuracy: 0.000_1)
        XCTAssertTrue(credentials.isExpired(at: expiresAt))
        XCTAssertFalse(credentials.isExpired(at: expiresAt.addingTimeInterval(-1)))
    }

    func testTokenWithNoExpiryIsNeverExpired() throws {
        let credentials = try XCTUnwrap(CredentialsService.credentials(fromJSONText: #"{"accessToken":"token"}"#))
        XCTAssertFalse(credentials.isExpired(at: Date(timeIntervalSince1970: 1_800_000_000)))
    }

    func testCredentialNestingSkipsEmptyTokens() throws {
        let text = """
        {"claudeAiOauth":{"accessToken":"  "},"claude_ai_oauth":{"accessToken":"nested"},"accessToken":"top"}
        """
        let credentials = try XCTUnwrap(CredentialsService.credentials(fromJSONText: text))
        XCTAssertEqual(credentials.token, "nested")
        let fractional = """
        {"oauth":{"accessToken":"token","expiresAt":1790153332424.5}}
        """
        let bare = try XCTUnwrap(CredentialsService.credentials(fromJSONText: fractional))
        XCTAssertNil(bare.expiresAt)
    }

    func testCredentialPrecedenceUsesEnvThenKeychainThenFiles() throws {
        let home = temporaryDirectory()
        defer { remove(home) }
        let claude = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        let hidden = claude.appendingPathComponent(".credentials.json")
        let visible = claude.appendingPathComponent("credentials.json")
        try Data(#"{"accessToken":"from-hidden"}"#.utf8).write(to: hidden)
        try Data(#"{"accessToken":"from-visible"}"#.utf8).write(to: visible)

        var keychainReads = 0
        let fromEnv = CredentialsService.load(
            environment: [CredentialsService.tokenEnvironment: "  from-env  "],
            home: home.path,
            keychainJSON: {
                keychainReads += 1
                return #"{"accessToken":"from-keychain"}"#
            },
            readFile: { path in
                guard let data = FileManager.default.contents(atPath: path) else { return nil }
                return String(data: data, encoding: .utf8)
            }
        )
        XCTAssertEqual(keychainReads, 0)
        guard case .found(let envCredentials) = fromEnv else {
            return XCTFail("expected the environment token")
        }
        XCTAssertEqual(envCredentials.token, "from-env")
        XCTAssertNil(envCredentials.expiresAt)

        let fromKeychain = CredentialsService.load(
            environment: [CredentialsService.tokenEnvironment: "   "],
            home: home.path,
            keychainJSON: { #"{"accessToken":"from-keychain"}"# },
            readFile: { _ in XCTFail("files are behind the keychain"); return nil }
        )
        guard case .found(let keychainCredentials) = fromKeychain else {
            return XCTFail("expected the keychain token")
        }
        XCTAssertEqual(keychainCredentials.token, "from-keychain")

        let fromFile = CredentialsService.load(
            environment: [:],
            home: home.path,
            keychainJSON: { "not json" },
            readFile: { path in
                guard let data = FileManager.default.contents(atPath: path) else { return nil }
                return String(data: data, encoding: .utf8)
            }
        )
        guard case .found(let fileCredentials) = fromFile else {
            return XCTFail("expected the hidden credential file")
        }
        XCTAssertEqual(fileCredentials.token, "from-hidden")

        try FileManager.default.removeItem(at: hidden)
        let fromVisible = CredentialsService.load(
            environment: [:],
            home: home.path,
            keychainJSON: { nil },
            readFile: { path in
                guard let data = FileManager.default.contents(atPath: path) else { return nil }
                return String(data: data, encoding: .utf8)
            }
        )
        guard case .found(let visibleCredentials) = fromVisible else {
            return XCTFail("expected the second credential file")
        }
        XCTAssertEqual(visibleCredentials.token, "from-visible")

        try FileManager.default.removeItem(at: visible)
        XCTAssertEqual(
            CredentialsService.load(environment: [:], home: home.path, keychainJSON: { nil }, readFile: { _ in nil }),
            .missing
        )
    }

    func testSeatTierComesFromTheProfile() throws {
        let home = temporaryDirectory()
        defer { remove(home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let profile = home.appendingPathComponent(".claude.json")
        try Data(#"{"oauthAccount":{"seatTier":"team_standard"}}"#.utf8).write(to: profile)
        let seat = CredentialsService.seatTier(home: home.path) { path in
            guard let data = FileManager.default.contents(atPath: path) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        XCTAssertEqual(seat, "team_standard")
        let credentials = CredentialLoad.found(StoredCredentials(
            token: "token",
            expiresAt: nil,
            subscriptionType: "team",
            rateLimitTier: "default_raven"
        ))
        XCTAssertEqual(CredentialsService.planLabel(credentials: credentials, seatTier: seat), "Team Standard plan")
        XCTAssertNil(CredentialsService.planLabel(credentials: .missing, seatTier: seat))
    }

    func testKeychainCommandDoesNotCarryAToken() {
        XCTAssertEqual(CredentialsService.keychainExecutable, "/usr/bin/security")
        XCTAssertEqual(
            CredentialsService.keychainArguments,
            ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        )
        XCTAssertFalse(CredentialsService.keychainArguments.joined(separator: " ").contains("token"))
    }

    func testQuotaShapesAndTimestamps() throws {
        let body = """
        {
          "five_hour": {"utilization": 38.5, "resets_at": "2026-01-02T03:04:05Z", "used_dollars": 1, "limit_dollars": 2},
          "seven_day": {"utilization": null, "used_dollars": 25, "limit_dollars": 100, "resets_at": 1767308645},
          "seven_day_opus": {"utilization": 10, "resets_at": 1767308645.9},
          "ignored": true
        }
        """.data(using: .utf8)!
        let limits = try XCTUnwrap(try QuotaService.parseLimits(body).get())
        let fiveHour = try XCTUnwrap(limits.fiveHour)
        XCTAssertEqual(fiveHour.used, 38.5, accuracy: 0.000_1)
        XCTAssertEqual(fiveHour.remaining, 61.5, accuracy: 0.000_1)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        XCTAssertEqual(fiveHour.resetsAt, formatter.date(from: "2026-01-02T03:04:05Z"))

        let sevenDay = try XCTUnwrap(limits.sevenDay)
        XCTAssertEqual(sevenDay.used, 25, accuracy: 0.000_1)
        XCTAssertEqual(sevenDay.remaining, 75, accuracy: 0.000_1)
        XCTAssertEqual(sevenDay.resetsAt, Date(timeIntervalSince1970: 1_767_308_645))

        // The retired Opus weekly window is ignored.
        XCTAssertEqual(limits.windows.map { $0.0 }, [.fiveHour, .sevenDay])

        let dollarsOnly = try XCTUnwrap(QuotaService.parseWindow([
            "utilization": NSNull(), "used_dollars": 25.0, "limit_dollars": 100.0, "resets_at": NSNull(),
        ]))
        XCTAssertEqual(dollarsOnly.used, 25)
        XCTAssertEqual(dollarsOnly.remaining, 75)
        XCTAssertNil(QuotaService.parseWindow([
            "utilization": NSNull(), "used_dollars": NSNull(), "limit_dollars": NSNull(),
        ]))
        XCTAssertNil(QuotaService.parseWindow(["used_dollars": 25.0, "limit_dollars": 0.0]))
        let fractional = QuotaService.parseReset("2026-01-02T03:04:05.123Z")
        XCTAssertNotNil(fractional)
        XCTAssertNil(QuotaService.parseReset("not-a-date"))
    }

    func testRetiredOpusQuotaCannotFailParsing() throws {
        let malformed: [Any] = [
            NSNull(), "invalid", true, 42, ["bad"],
            ["utilization": "invalid", "used_dollars": false, "limit_dollars": [], "resets_at": [:]],
        ]
        let active: [String: Any] = [
            "five_hour": ["utilization": 20], "seven_day": ["utilization": 30],
        ]
        let expected = QuotaLimits(fiveHour: QuotaWindow(used: 20), sevenDay: QuotaWindow(used: 30))
        XCTAssertEqual(try QuotaService.parseLimits(JSONSerialization.data(withJSONObject: active)).get(), expected)
        for value in malformed {
            var body = active
            body["seven_day_opus"] = value
            XCTAssertEqual(try QuotaService.parseLimits(JSONSerialization.data(withJSONObject: body)).get(), expected)
            let opusOnly = try XCTUnwrap(try QuotaService.parseLimits(
                JSONSerialization.data(withJSONObject: ["seven_day_opus": value])
            ).get())
            XCTAssertTrue(opusOnly.isEmpty)
        }
        XCTAssertThrowsError(try QuotaService.parseLimits(Data(
            #"{"five_hour":{"utilization":"invalid"},"seven_day_opus":true}"#.utf8
        )).get(), "Active windows must still be validated")
    }

    func testEmptyQuotaBodyIsASuccessfulEmptyResult() throws {
        let limits = try XCTUnwrap(try QuotaService.parseLimits(Data("{}".utf8)).get())
        XCTAssertTrue(limits.isEmpty)
        XCTAssertThrowsError(try QuotaService.parseLimits(Data("[]".utf8)).get())
    }

    func testQuotaErrorsDoNotEchoTheBody() {
        let body = Data(#"{"accessToken":"sk-secret"}"#.utf8)
        switch QuotaService.interpret(status: 401, body: body) {
        case .failure(let failure):
            XCTAssertEqual(failure.message, "Usage API returned HTTP 401")
            XCTAssertFalse(failure.message.contains("sk-secret"))
        case .success:
            XCTFail("expected the status error")
        }
        switch QuotaService.interpret(status: 200, body: Data("not-json".utf8)) {
        case .failure(let failure):
            XCTAssertEqual(failure.message, "usage API JSON: invalid body")
            XCTAssertFalse(failure.message.contains("not-json"))
        case .success:
            XCTFail("expected the JSON error")
        }
        XCTAssertTrue(QuotaService.isUnauthorized(QuotaService.missingTokenMessage))
        XCTAssertTrue(QuotaService.isUnauthorized("Usage API returned HTTP 401"))
        XCTAssertFalse(QuotaService.isUnauthorized("Usage API returned HTTP 500"))
        XCTAssertFalse(QuotaService.isUnauthorized("Usage API: connection reset"))
        XCTAssertTrue(QuotaService.isExpired(QuotaService.expiredTokenMessage))
        XCTAssertFalse(QuotaService.isUnauthorized(QuotaService.expiredTokenMessage))
        XCTAssertFalse(QuotaService.isMissingToken(QuotaService.expiredTokenMessage))
        XCTAssertTrue(QuotaService.isMissingToken(QuotaService.missingTokenMessage))
        XCTAssertFalse(QuotaService.isMissingToken("Usage API returned HTTP 401"))
        let transport = QuotaService.transportMessage(URLError(.networkConnectionLost))
        XCTAssertFalse(QuotaService.isUnauthorized(transport))
        XCTAssertFalse(transport.contains("Bearer"))
    }

    func testUsageRequestIsAGetWithOAuthHeadersAndNoBody() {
        let token = "token-value"
        let request = QuotaService.usageRequest(token: token, userAgent: "claude-code/2.1.80")
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertFalse(request.url?.absoluteString.contains(token) ?? true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "claude-code/2.1.80")
        let hits = request.allHTTPHeaderFields?.filter { $0.value.contains(token) }.map(\.key) ?? []
        XCTAssertEqual(hits, ["Authorization"])
        XCTAssertEqual(QuotaService.userAgent(version: nil), "claude-code/2.1.80")
        XCTAssertEqual(QuotaService.userAgent(version: ""), "claude-code/2.1.80")
        XCTAssertEqual(QuotaService.userAgent(version: "2.1.81"), "claude-code/2.1.81")
    }

    func testApiBillingSkipsTheQuotaRequest() async {
        let requests = Counter()
        let result = await SessionService.sessionResult(
            binaryFound: true,
            billing: .apiKey,
            credentials: .found(sampleCredentials(expiresAt: nil)),
            planLabel: "Max plan",
            now: Date()
        ) {
            requests.value += 1
            return .success(QuotaLimits(fiveHour: QuotaWindow(used: 10)))
        }
        XCTAssertEqual(requests.value, 0)
        XCTAssertEqual(result.state, .apiBilling)
        XCTAssertEqual(result.accountLabel, "Pay per token · API key")
        XCTAssertNil(result.limits)
        XCTAssertNil(result.error)
    }

    func testMissingTokenDistinguishesSignedOutFromNotInstalled() async {
        let signedOut = await session(binaryFound: true, credentials: .missing, fetch: {
            XCTFail("missing token must not fetch")
            return .failure(QuotaFailure(message: "nope"))
        })
        XCTAssertEqual(signedOut.state, .signedOut)
        XCTAssertNil(signedOut.accountLabel)
        XCTAssertNil(signedOut.limits)

        let missingCLI = await session(binaryFound: false, credentials: .missing, fetch: {
            XCTFail("missing token must not fetch")
            return .failure(QuotaFailure(message: "nope"))
        })
        XCTAssertEqual(missingCLI.state, .cliMissing)
    }

    func testExpiredTokenSkipsTheRequestAndKeepsThePlan() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let requests = Counter()
        let result = await session(
            binaryFound: false,
            credentials: .found(sampleCredentials(expiresAt: now)),
            planLabel: "Max 20x plan",
            now: now
        ) {
            requests.value += 1
            return .success(QuotaLimits())
        }
        XCTAssertEqual(requests.value, 0)
        XCTAssertEqual(result.state, .expired)
        XCTAssertEqual(result.accountLabel, "Max 20x plan")
        XCTAssertNil(result.limits)
        XCTAssertNil(result.error)
    }

    func testUnauthorizedDropsThePlanAndOtherErrorsKeepIt() async {
        let unauthorized = await session(
            credentials: .found(sampleCredentials(expiresAt: nil)),
            planLabel: "Pro plan",
            fetch: { .failure(QuotaFailure(message: "Usage API returned HTTP 401")) }
        )
        XCTAssertEqual(unauthorized.state, .signedOut)
        XCTAssertNil(unauthorized.accountLabel)
        XCTAssertNil(unauthorized.error)

        let unavailable = await session(
            credentials: .found(sampleCredentials(expiresAt: nil)),
            planLabel: "Pro plan",
            fetch: { .failure(QuotaFailure(message: "Usage API returned HTTP 500")) }
        )
        XCTAssertEqual(unavailable.state, .unavailable)
        XCTAssertEqual(unavailable.accountLabel, "Pro plan")
        XCTAssertEqual(unavailable.error, "Usage API returned HTTP 500")
        XCTAssertNil(unavailable.limits)

        let ready = await session(
            credentials: .found(sampleCredentials(expiresAt: nil)),
            planLabel: "Pro plan",
            fetch: { .success(QuotaLimits()) }
        )
        XCTAssertEqual(ready.state, .ready)
        XCTAssertEqual(ready.accountLabel, "Pro plan")
        XCTAssertEqual(ready.limits?.isEmpty, true)
        XCTAssertNil(ready.error)
    }

    func testCaptureDiscardsStderrAndStopsAtTheMarker() throws {
        let stderrFlood = try XCTUnwrap(ProcessRunner.capture(
            executable: "/bin/sh",
            arguments: ["-c", "dd if=/dev/zero bs=1024 count=128 >/dev/null; dd if=/dev/zero bs=1024 count=128 >&2; printf ok"],
            timeout: 3
        ))
        XCTAssertFalse(stderrFlood.timedOut)
        XCTAssertEqual(String(data: stderrFlood.stdout, encoding: .utf8), "ok")

        let started = Date()
        let marked = try XCTUnwrap(ProcessRunner.capture(
            executable: "/bin/sh",
            arguments: ["-c", "/usr/bin/printf '%s\\n' noise __CLAUDE_USAGE_PATH_END__; exec sleep 20"],
            timeout: 5,
            untilMarker: "__CLAUDE_USAGE_PATH_END__"
        ))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertFalse(marked.timedOut)
        XCTAssertEqual(
            String(data: marked.stdout, encoding: .utf8),
            "noise\n__CLAUDE_USAGE_PATH_END__\n"
        )
        assertDead(marked.pid)
    }

    func testCaptureTimesOutWithoutReturningPartialOutput() throws {
        let started = Date()
        let result = try XCTUnwrap(ProcessRunner.capture(
            executable: "/bin/sh",
            arguments: ["-c", "printf '%s\\n' secret-partial; exec sleep 20"],
            timeout: 0.3
        ))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertTrue(result.timedOut)
        XCTAssertNil(ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "printf '%s\\n' secret-partial; exec sleep 20"],
            timeout: 0.3
        ))
        assertDead(result.pid)

        let rejected = ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "printf '%s' 'super-secret-token'; exit 1"],
            timeout: 2,
            requireSuccess: true
        )
        XCTAssertNil(rejected)
        let kept = try XCTUnwrap(ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "printf '%s' '{\"ok\":true}'; exit 1"],
            timeout: 2
        ))
        XCTAssertEqual(String(data: kept, encoding: .utf8), "{\"ok\":true}")
    }

    func testCaptureDrainsPastThePipeBufferAndTheByteCap() throws {
        let full = try XCTUnwrap(ProcessRunner.capture(
            executable: "/bin/sh",
            arguments: ["-c", "dd if=/dev/zero bs=1024 count=256 2>/dev/null"],
            timeout: 3
        ))
        XCTAssertFalse(full.timedOut)
        XCTAssertEqual(full.stdout.count, 256 * 1024)

        let capped = try XCTUnwrap(ProcessRunner.capture(
            executable: "/bin/sh",
            arguments: ["-c", "dd if=/dev/zero bs=1024 count=512 2>/dev/null"],
            timeout: 3,
            maxCaptureBytes: 65_536
        ))
        XCTAssertFalse(capped.timedOut)
        XCTAssertEqual(capped.stdout.count, 65_536)
        XCTAssertNil(ProcessRunner.capture(executable: "/no/such/binary", arguments: [], timeout: 1))
    }

    func testSignalResistantProcessIsKilled() throws {
        let started = Date()
        let result = try XCTUnwrap(ProcessRunner.capture(
            executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; while :; do :; done"],
            timeout: 0.3
        ))
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
        XCTAssertTrue(result.timedOut)
        assertDead(result.pid)
    }

    private func session(
        binaryFound: Bool = true,
        credentials: CredentialLoad,
        planLabel: String? = nil,
        now: Date = Date(timeIntervalSince1970: 1_800_000_000),
        fetch: @escaping () async -> Result<QuotaLimits, QuotaFailure>
    ) async -> SessionResult {
        await SessionService.sessionResult(
            binaryFound: binaryFound,
            billing: nil,
            credentials: credentials,
            planLabel: planLabel,
            now: now,
            fetch: fetch
        )
    }

    private func sampleCredentials(expiresAt: Date?) -> StoredCredentials {
        StoredCredentials(token: "token", expiresAt: expiresAt, subscriptionType: "pro", rateLimitTier: nil)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("claude-usage-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func assertDead(_ pid: Int32) {
        if kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
            XCTFail("process \(pid) was still running")
        }
    }
}

private final class Counter {
    var value = 0
}
