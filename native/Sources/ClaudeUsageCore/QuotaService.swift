import Foundation

struct QuotaFailure: Error, Equatable {
    var message: String
}

enum QuotaService {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let oauthBeta = "oauth-2025-04-20"
    static let fallbackVersion = "2.1.80"
    static let requestTimeout: TimeInterval = 15
    static let missingTokenMessage = "No Claude OAuth token found. Log in with Claude Code first."
    static let expiredTokenMessage = "Claude Code's access token has expired."

    private static let cachedUserAgent: String = {
        let version = CLIService.locate().flatMap { CLIService.version(binary: $0) }
        return userAgent(version: version)
    }()

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: RedirectStopper(), delegateQueue: nil)
    }()

    static func userAgent(version: String?) -> String {
        let resolved = version.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackVersion
        return "claude-code/\(resolved)"
    }

    static func isMissingToken(_ error: String) -> Bool {
        error == missingTokenMessage
    }

    static func isExpired(_ error: String) -> Bool {
        error == expiredTokenMessage
    }

    /// A 401, or no token to send, means the session is over. An expired token
    /// is neither: Claude Code replaces it the next time it runs.
    static func isUnauthorized(_ error: String) -> Bool {
        isMissingToken(error) || error.hasSuffix("HTTP 401")
    }

    static func httpStatusMessage(_ status: Int) -> String {
        "Usage API returned HTTP \(status)"
    }

    static func transportMessage(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return "Usage API: URL error \(nsError.code)"
        }
        return "Usage API: connection failed"
    }

    static func usageRequest(token: String, userAgent: String) -> URLRequest {
        var request = URLRequest(url: usageURL, timeoutInterval: requestTimeout)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(oauthBeta, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Sends the stored access token. There is no refresh request.
    static func requestUsage(token: String) async -> Result<QuotaLimits, QuotaFailure> {
        let userAgent = await runBlockingIO { cachedUserAgent }
        let request = usageRequest(token: token, userAgent: userAgent)
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            return interpret(status: status, body: data)
        } catch {
            return .failure(QuotaFailure(message: transportMessage(error)))
        }
    }

    static func interpret(status: Int, body: Data) -> Result<QuotaLimits, QuotaFailure> {
        guard (200..<300).contains(status) else {
            return .failure(QuotaFailure(message: httpStatusMessage(status)))
        }
        return parseLimits(body)
    }

    static func parseLimits(_ data: Data) -> Result<QuotaLimits, QuotaFailure> {
        guard let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any] else {
            return .failure(QuotaFailure(message: "usage API JSON: invalid body"))
        }
        // Validate only active windows. Retired keys may have arbitrary shapes.
        for key in ["five_hour", "seven_day"] {
            guard let raw = object[key], !(raw is NSNull) else { continue }
            guard let window = raw as? [String: Any] else {
                return .failure(QuotaFailure(message: "usage API JSON: invalid quota window"))
            }
            for field in ["utilization", "used_dollars", "limit_dollars"] {
                guard let value = window[field], !(value is NSNull) else { continue }
                guard JSONValues.double(value) != nil else {
                    return .failure(QuotaFailure(message: "usage API JSON: invalid quota number"))
                }
            }
        }
        return .success(QuotaLimits(
            fiveHour: parseWindow(object["five_hour"]),
            sevenDay: parseWindow(object["seven_day"])
        ))
    }

    /// Utilization is a percentage. When only the dollar fields are filled in,
    /// the share of the limit spent is the same figure.
    static func parseWindow(_ value: Any?) -> QuotaWindow? {
        guard let object = value as? [String: Any] else { return nil }
        let used: Double
        if let utilization = JSONValues.double(object["utilization"]) {
            used = utilization
        } else if let spent = JSONValues.double(object["used_dollars"]),
                  let limit = JSONValues.double(object["limit_dollars"]),
                  limit > 0 {
            used = spent / limit * 100
        } else {
            return nil
        }
        guard used.isFinite else { return nil }
        return QuotaWindow(used: used, resetsAt: parseReset(object["resets_at"]))
    }

    /// RFC 3339 on some plans, epoch seconds on others.
    static func parseReset(_ value: Any?) -> Date? {
        if let text = value as? String {
            return parseRFC3339(text)
        }
        if let seconds = JSONValues.epochSeconds(value) {
            return Date(timeIntervalSince1970: TimeInterval(seconds))
        }
        return nil
    }

    private static func parseRFC3339(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) {
            return date
        }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return basic.date(from: text)
    }
}

/// Refuses redirects so the bearer token stays on the usage URL.
private final class RedirectStopper: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
