//! How Claude Code is paid for, which decides whether there are plan limits to
//! show at all. The 5-hour and weekly windows belong to a Claude subscription;
//! an API key or a cloud provider is billed per token and has neither.

use serde_json::Value;

/// Set by `claude auth status` when an API key outranks the claude.ai login.
/// Its `authMethod` still reads `claude.ai` in that case, so this is the field
/// that actually says the subscription is not the one being billed.
const API_KEY_SOURCE: &str = "apiKeySource";
const API_PROVIDER: &str = "apiProvider";
const AUTH_METHOD: &str = "authMethod";
const FIRST_PARTY: &str = "firstParty";
/// What `authMethod` reads for a bearer token handed over in the environment,
/// whether that is `ANTHROPIC_AUTH_TOKEN` for a gateway or
/// `CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token`.
const ENV_TOKEN_METHOD: &str = "oauth_token";

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Account {
    /// A Claude plan. `plan` is its name when the credentials say, e.g. `Max 20x`.
    Subscription { plan: Option<String> },
    /// Billed per token, with no plan limits behind it.
    Api(ApiBilling),
}

/// What Claude Code is sending its requests through when it is not using a
/// subscription.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ApiBilling {
    ApiKey,
    AuthToken,
    Bedrock,
    Vertex,
    Foundry,
    OtherProvider,
}

impl ApiBilling {
    /// For the header, next to the title.
    pub fn name(self) -> &'static str {
        match self {
            Self::ApiKey => "API key",
            Self::AuthToken => "API auth token",
            Self::Bedrock => "Amazon Bedrock",
            Self::Vertex => "Google Vertex AI",
            Self::Foundry => "Microsoft Foundry",
            Self::OtherProvider => "cloud provider",
        }
    }

    /// For a sentence: "billed per token through {this}".
    pub fn phrase(self) -> &'static str {
        match self {
            Self::ApiKey => "an API key",
            Self::AuthToken => "an API auth token",
            Self::Bedrock => "Amazon Bedrock",
            Self::Vertex => "Google Vertex AI",
            Self::Foundry => "Microsoft Foundry",
            Self::OtherProvider => "a cloud provider",
        }
    }
}

impl Account {
    /// The one-line description the header carries, or `None` for a
    /// subscription whose plan the credentials did not name.
    pub fn label(&self) -> Option<String> {
        match self {
            Self::Subscription { plan } => plan.as_ref().map(|plan| format!("{plan} plan")),
            Self::Api(billing) => Some(format!("Pay per token · {}", billing.name())),
        }
    }
}

/// Reads `claude auth status --json` for signs that Claude Code is billed per
/// token. `None` means nothing there rules out the subscription, which is also
/// the answer when the status could not be read: the OAuth token decides the
/// rest, as it always has. `gateway_token` is whether the shell sets
/// `ANTHROPIC_AUTH_TOKEN` without `CLAUDE_CODE_OAUTH_TOKEN`, the only way to
/// tell a gateway's token from a subscription's when both read `oauth_token`.
pub fn api_billing(status: &Value, gateway_token: bool) -> Option<ApiBilling> {
    let text = |key: &str| status.get(key).and_then(Value::as_str);

    match text(API_PROVIDER) {
        None | Some(FIRST_PARTY) => {}
        Some("bedrock") => return Some(ApiBilling::Bedrock),
        Some("vertex") => return Some(ApiBilling::Vertex),
        Some("foundry") => return Some(ApiBilling::Foundry),
        Some(_) => return Some(ApiBilling::OtherProvider),
    }
    if text(API_KEY_SOURCE).is_some_and(|source| !source.is_empty()) {
        return Some(ApiBilling::ApiKey);
    }
    if text(AUTH_METHOD) == Some(ENV_TOKEN_METHOD) && gateway_token {
        return Some(ApiBilling::AuthToken);
    }
    None
}

/// The plan's display name from the fields Claude Code keeps with its OAuth
/// token and in `~/.claude.json`. `subscription_type` is the plan
/// (`max`, `team`), `rate_limit_tier` separates Max 5x from 20x, and
/// `seat_tier` (`team_standard`) separates the seats on Team and Enterprise,
/// whose rate-limit tier is an internal codename.
pub fn plan_name(
    subscription_type: Option<&str>,
    rate_limit_tier: Option<&str>,
    seat_tier: Option<&str>,
) -> Option<String> {
    let raw = subscription_type?.trim();
    let normalized = squash(raw);
    // The SDK spells these out, e.g. `claude_max_subscription`.
    let plan = normalized.strip_prefix("claude").unwrap_or(&normalized);
    let plan = plan.strip_suffix("subscription").unwrap_or(plan);
    let tier = rate_limit_tier.map(squash).unwrap_or_default();

    let name = match plan {
        "" => return None,
        "max20" | "max20x" => "Max 20x".into(),
        "max5" | "max5x" => "Max 5x".into(),
        "max" | "maxplan" if tier.contains("20x") => "Max 20x".into(),
        "max" | "maxplan" if tier.contains("5x") => "Max 5x".into(),
        "max" | "maxplan" => "Max".into(),
        "pro" => "Pro".into(),
        "free" => "Free".into(),
        "team" => with_seat("Team", "team", seat_tier),
        "enterprise" => with_seat("Enterprise", "enterprise", seat_tier),
        _ => title_case(raw),
    };
    Some(name)
}

/// `Team Standard` from `team_standard`. A seat tier that does not start with
/// the plan's own name is some other scheme, and the plan name alone is safer
/// than guessing at it.
fn with_seat(plan: &str, prefix: &str, seat_tier: Option<&str>) -> String {
    let seat = seat_tier
        .map(|tier| tier.trim().to_ascii_lowercase())
        .and_then(|tier| {
            tier.strip_prefix(prefix)
                .map(|rest| rest.trim_start_matches(['_', '-', ' ']).to_string())
        })
        .filter(|seat| !seat.is_empty());
    match seat {
        Some(seat) => format!("{plan} {}", title_case(&seat)),
        None => plan.into(),
    }
}

fn squash(value: &str) -> String {
    value
        .chars()
        .filter(|ch| !matches!(ch, ' ' | '_' | '-'))
        .flat_map(char::to_lowercase)
        .collect()
}

fn title_case(value: &str) -> String {
    value
        .split(['_', '-', ' '])
        .filter(|part| !part.is_empty())
        .map(|part| {
            let mut chars = part.chars();
            chars.next().map_or_else(String::new, |first| {
                first
                    .to_uppercase()
                    .chain(chars.flat_map(char::to_lowercase))
                    .collect()
            })
        })
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn plans_read_the_way_claude_names_them() {
        assert_eq!(plan_name(Some("pro"), None, None).as_deref(), Some("Pro"));
        assert_eq!(
            plan_name(Some("max"), Some("default_claude_max_20x"), None).as_deref(),
            Some("Max 20x")
        );
        assert_eq!(
            plan_name(Some("max"), Some("default_claude_max_5x"), None).as_deref(),
            Some("Max 5x")
        );
        assert_eq!(plan_name(Some("max"), None, None).as_deref(), Some("Max"));
        assert_eq!(
            plan_name(
                Some("claude_max_subscription"),
                Some("default_claude_max_20x"),
                None
            )
            .as_deref(),
            Some("Max 20x")
        );
    }

    /// Team's rate-limit tier is a codename, so the seat comes from elsewhere.
    #[test]
    fn team_and_enterprise_take_their_seat_tier() {
        assert_eq!(
            plan_name(Some("team"), Some("default_raven"), Some("team_standard")).as_deref(),
            Some("Team Standard")
        );
        assert_eq!(
            plan_name(Some("team"), Some("default_raven"), None).as_deref(),
            Some("Team")
        );
        assert_eq!(
            plan_name(Some("enterprise"), None, Some("something_else")).as_deref(),
            Some("Enterprise")
        );
    }

    #[test]
    fn an_unknown_or_missing_plan() {
        assert_eq!(
            plan_name(Some("student_plus"), None, None).as_deref(),
            Some("Student Plus")
        );
        assert_eq!(plan_name(None, Some("default_claude_max_20x"), None), None);
        assert_eq!(plan_name(Some("  "), None, None), None);
    }

    /// The shapes below are what `claude auth status --json` printed for each
    /// setup, with the account fields left out.
    #[test]
    fn a_claude_ai_login_is_a_subscription() {
        let status = json!({
            "loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty",
            "subscriptionType": "team"
        });
        assert_eq!(api_billing(&status, false), None);
    }

    #[test]
    fn an_api_key_outranks_the_login() {
        let status = json!({
            "loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty",
            "apiKeySource": "ANTHROPIC_API_KEY", "subscriptionType": null
        });
        assert_eq!(api_billing(&status, false), Some(ApiBilling::ApiKey));
    }

    #[test]
    fn cloud_providers_are_billed_per_token() {
        for (provider, billing) in [
            ("bedrock", ApiBilling::Bedrock),
            ("vertex", ApiBilling::Vertex),
            ("foundry", ApiBilling::Foundry),
            ("someday", ApiBilling::OtherProvider),
        ] {
            let status = json!({
                "loggedIn": true, "authMethod": "third_party", "apiProvider": provider
            });
            assert_eq!(api_billing(&status, false), Some(billing));
        }
    }

    #[test]
    fn an_environment_token_is_only_api_billing_when_it_is_a_gateways() {
        let status = json!({
            "loggedIn": true, "authMethod": "oauth_token", "apiProvider": "firstParty"
        });
        assert_eq!(api_billing(&status, true), Some(ApiBilling::AuthToken));
        assert_eq!(api_billing(&status, false), None);
    }

    #[test]
    fn signed_out_is_not_api_billing() {
        let status = json!({
            "loggedIn": false, "authMethod": "none", "apiProvider": "firstParty"
        });
        assert_eq!(api_billing(&status, false), None);
    }

    #[test]
    fn labels() {
        assert_eq!(
            Account::Subscription {
                plan: Some("Max 20x".into())
            }
            .label()
            .as_deref(),
            Some("Max 20x plan")
        );
        assert_eq!(Account::Subscription { plan: None }.label(), None);
        assert_eq!(
            Account::Api(ApiBilling::Bedrock).label().as_deref(),
            Some("Pay per token · Amazon Bedrock")
        );
    }
}
