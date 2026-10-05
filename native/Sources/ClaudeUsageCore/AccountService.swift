import Foundation

/// How Claude Code is billed. Subscription windows exist only for a Claude plan.
/// An API key or a cloud provider is billed per token and has neither.
enum ApiBilling: Equatable {
    case apiKey
    case authToken
    case bedrock
    case vertex
    case foundry
    case otherProvider

    var name: String {
        switch self {
        case .apiKey: return "API key"
        case .authToken: return "API auth token"
        case .bedrock: return "Amazon Bedrock"
        case .vertex: return "Google Vertex AI"
        case .foundry: return "Microsoft Foundry"
        case .otherProvider: return "cloud provider"
        }
    }

    /// Sentence fragment: "billed per token through {phrase}".
    var phrase: String {
        switch self {
        case .apiKey: return "an API key"
        case .authToken: return "an API auth token"
        case .bedrock: return "Amazon Bedrock"
        case .vertex: return "Google Vertex AI"
        case .foundry: return "Microsoft Foundry"
        case .otherProvider: return "a cloud provider"
        }
    }

    var accountLabel: String {
        "Pay per token · \(name)"
    }
}

enum AccountService {
    /// `apiKeySource` is set when an API key outranks the claude.ai login.
    /// `authMethod` still reads `claude.ai` in that case.
    static func apiBilling(status: [String: Any], gatewayToken: Bool) -> ApiBilling? {
        switch status["apiProvider"] as? String {
        case nil, "firstParty":
            break
        case "bedrock":
            return .bedrock
        case "vertex":
            return .vertex
        case "foundry":
            return .foundry
        default:
            return .otherProvider
        }
        if let source = status["apiKeySource"] as? String, !source.isEmpty {
            return .apiKey
        }
        if (status["authMethod"] as? String) == "oauth_token" && gatewayToken {
            return .authToken
        }
        return nil
    }

    /// `subscription_type` is the plan, `rate_limit_tier` separates Max 5x from
    /// 20x, and `seat_tier` names the seat on Team and Enterprise.
    static func planName(
        subscriptionType: String?,
        rateLimitTier: String?,
        seatTier: String?
    ) -> String? {
        guard let raw = subscriptionType?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        let normalized = squash(raw)
        var plan = normalized
        if let stripped = removingPrefix("claude", from: plan) {
            plan = stripped
        }
        if let stripped = removingSuffix("subscription", from: plan) {
            plan = stripped
        }
        let tier = rateLimitTier.map(squash) ?? ""
        let name: String
        switch plan {
        case "":
            return nil
        case "max20", "max20x":
            name = "Max 20x"
        case "max5", "max5x":
            name = "Max 5x"
        case "max" where tier.contains("20x"), "maxplan" where tier.contains("20x"):
            name = "Max 20x"
        case "max" where tier.contains("5x"), "maxplan" where tier.contains("5x"):
            name = "Max 5x"
        case "max", "maxplan":
            name = "Max"
        case "pro":
            name = "Pro"
        case "free":
            name = "Free"
        case "team":
            name = withSeat("Team", prefix: "team", seatTier: seatTier)
        case "enterprise":
            name = withSeat("Enterprise", prefix: "enterprise", seatTier: seatTier)
        default:
            name = titleCase(raw)
        }
        return name
    }

    static func subscriptionLabel(
        subscriptionType: String?,
        rateLimitTier: String?,
        seatTier: String?
    ) -> String? {
        guard let name = planName(
            subscriptionType: subscriptionType,
            rateLimitTier: rateLimitTier,
            seatTier: seatTier
        ) else {
            return nil
        }
        return "\(name) plan"
    }

    /// `Team Standard` from `team_standard`. A seat that does not start with the
    /// plan name is left off, and the plan name stands alone.
    private static func withSeat(_ plan: String, prefix: String, seatTier: String?) -> String {
        guard let seatTier else { return plan }
        let lowered = asciiLowercased(seatTier.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let rest = removingPrefix(prefix, from: lowered) else { return plan }
        let seat = trimSeatSeparators(rest)
        if seat.isEmpty { return plan }
        return "\(plan) \(titleCase(seat))"
    }

    private static func trimSeatSeparators(_ value: String) -> String {
        var seat = value
        while let first = seat.first, first == "_" || first == "-" || first == " " {
            seat.removeFirst()
        }
        return seat
    }

    private static func squash(_ value: String) -> String {
        var result = ""
        for character in value {
            if character == " " || character == "_" || character == "-" { continue }
            result.append(contentsOf: String(character).lowercased())
        }
        return result
    }

    private static func titleCase(_ value: String) -> String {
        value.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " }).map { part in
            guard let first = part.first else { return "" }
            return String(first).uppercased() + String(part.dropFirst()).lowercased()
        }.joined(separator: " ")
    }

    private static func asciiLowercased(_ value: String) -> String {
        String(value.unicodeScalars.map { scalar in
            if scalar.value >= 65 && scalar.value <= 90 {
                return Character(UnicodeScalar(scalar.value + 32)!)
            }
            return Character(scalar)
        })
    }

    private static func removingPrefix(_ prefix: String, from value: String) -> String? {
        guard value.hasPrefix(prefix) else { return nil }
        return String(value.dropFirst(prefix.count))
    }

    private static func removingSuffix(_ suffix: String, from value: String) -> String? {
        guard value.hasSuffix(suffix) else { return nil }
        return String(value.dropLast(suffix.count))
    }
}
