import Foundation

public enum SessionService {
    /// Quota and account state only. Transcripts stay on `loadTranscripts()` so
    /// the store can rescan them on its own schedule.
    public static func load() async -> SessionResult {
        let located = await runBlockingIO { () -> (String?, ApiBilling?) in
            let binary = CLIService.locate()
            let billing = binary.flatMap { CLIService.billing(binary: $0) }
            return (binary, billing)
        }

        if let billing = located.1 {
            return SessionResult(state: .apiBilling, accountLabel: billing.accountLabel)
        }

        let prepared = await runBlockingIO { () -> (CredentialLoad, String?) in
            let credentials = CredentialsService.loadFromLiveSources()
            let plan = CredentialsService.planLabel(
                credentials: credentials,
                seatTier: CredentialsService.liveSeatTier()
            )
            return (credentials, plan)
        }

        return await sessionResult(
            binaryFound: located.0 != nil,
            billing: nil,
            credentials: prepared.0,
            planLabel: prepared.1,
            now: Date()
        ) {
            guard case .found(let credentials) = prepared.0 else {
                return .failure(QuotaFailure(message: QuotaService.missingTokenMessage))
            }
            return await QuotaService.requestUsage(token: credentials.token)
        }
    }

    /// A subscription tick reads credentials and quotas without starting the CLI.
    public static func pollQuotas(accountLabel: String?) async -> SessionResult {
        let credentials = await runBlockingIO { CredentialsService.loadFromLiveSources() }
        return await sessionResult(binaryFound: true, billing: nil, credentials: credentials,
                                   planLabel: accountLabel, now: Date()) {
            guard case .found(let value) = credentials else {
                return .failure(QuotaFailure(message: QuotaService.missingTokenMessage))
            }
            return await QuotaService.requestUsage(token: value.token)
        }
    }

    /// API accounts only need a billing check until the account changes.
    public static func pollBillingLabel() async -> String? {
        await runBlockingIO { CLIService.locate().flatMap { CLIService.billing(binary: $0)?.accountLabel } }
    }

    public static func readTranscripts() async throws -> UsageReport {
        let result: Result<UsageReport, Error> = await runBlockingIO { Result { try loadTranscripts() } }
        return try result.get()
    }

    /// Login-shell `CLAUDE_CONFIG_DIR` overlaid on the process environment.
    /// Auth tokens are not copied into that environment.
    public static func loadTranscripts() throws -> UsageReport {
        try TranscriptLoader.load(environment: CLIService.liveTranscriptEnvironment())
    }

    static func sessionResult(
        binaryFound: Bool,
        billing: ApiBilling?,
        credentials: CredentialLoad,
        planLabel: String?,
        now: Date,
        fetch: () async -> Result<QuotaLimits, QuotaFailure>
    ) async -> SessionResult {
        if let billing {
            return SessionResult(state: .apiBilling, accountLabel: billing.accountLabel)
        }
        switch credentials {
        case .missing:
            return SessionResult(state: binaryFound ? .signedOut : .cliMissing)
        case .found(let credentials):
            if credentials.isExpired(at: now) {
                return SessionResult(state: .expired, accountLabel: planLabel)
            }
            switch await fetch() {
            case .success(let limits):
                return SessionResult(state: .ready, accountLabel: planLabel, limits: limits)
            case .failure(let failure) where QuotaService.isUnauthorized(failure.message):
                return SessionResult(state: .signedOut)
            case .failure(let failure) where QuotaService.isExpired(failure.message):
                return SessionResult(state: .expired, accountLabel: planLabel)
            case .failure(let failure):
                return SessionResult(state: .unavailable, accountLabel: planLabel, error: failure.message)
            }
        }
    }
}

/// Blocking shell and keychain operations run on a dispatch worker, outside Swift's cooperative pool.
func runBlockingIO<Value>(_ operation: @escaping () -> Value) async -> Value {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            continuation.resume(returning: operation())
        }
    }
}
