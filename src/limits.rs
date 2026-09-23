use crate::account;
use crate::cli;
use crate::settings::{MenuBarSettings, PercentMode};
use chrono::{DateTime, Duration, Utc};
use serde::Deserialize;
use serde_json::Value;
use std::process::Command;
use std::sync::OnceLock;
use std::time::Duration as StdDuration;

const USAGE_URL: &str = "https://api.anthropic.com/api/oauth/usage";
/// Keychain item Claude Code stores its OAuth credentials under.
const KEYCHAIN_SERVICE: &str = "Claude Code-credentials";
const TOKEN_ENV: &str = "CLAUDE_OAUTH_ACCESS_TOKEN";
const MISSING_TOKEN: &str = "No Claude OAuth token found. Log in with Claude Code first.";
/// Claude Code's access tokens last eight hours and only Claude Code refreshes
/// them, so a stretch without running it leaves an expired token behind a
/// login that is still good.
const EXPIRED_TOKEN: &str = "Claude Code's access token has expired.";
/// Where Claude Code caches the account profile, relative to `$HOME`.
const PROFILE_FILE: &str = ".claude.json";
/// Checked in order when the keychain lookup fails, relative to `$HOME`.
const CREDENTIAL_FILES: [&str; 2] = [".claude/.credentials.json", ".claude/credentials.json"];
/// The usage endpoint is OAuth-only and gated behind this beta header.
const OAUTH_BETA: &str = "oauth-2025-04-20";
const REQUEST_TIMEOUT: StdDuration = StdDuration::from_secs(15);
/// Reported when `claude --version` cannot be read, including when the CLI is
/// not installed and the token came from elsewhere. The endpoint rejects
/// requests without a plausible Claude Code user agent, so any recent version
/// works; this one only needs bumping if the server starts refusing it.
const FALLBACK_CLI_VERSION: &str = "2.1.80";
/// The API reports utilization as a percentage, so remaining is the complement.
const FULL_PERCENT: f64 = 100.0;

#[derive(Clone, Debug)]
pub struct QuotaWindow {
    pub used: f64,
    pub remaining: f64,
    pub resets_at: Option<DateTime<Utc>>,
}

#[derive(Clone, Debug, Default)]
pub struct QuotaLimits {
    pub five_hour: Option<QuotaWindow>,
    pub seven_day: Option<QuotaWindow>,
    pub seven_day_opus: Option<QuotaWindow>,
}

/// Which of the three windows a figure belongs to. Carries both namings so the
/// menu bar and the window cannot drift apart on what to call them.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum QuotaKind {
    FiveHour,
    SevenDay,
    Opus,
}

impl QuotaKind {
    /// For the menu bar, where width is the whole constraint.
    pub fn short_label(self) -> &'static str {
        match self {
            Self::FiveHour => "5h",
            Self::SevenDay => "7d",
            Self::Opus => "Opus",
        }
    }

    /// For the dropdown and the window, which have room to spell it out.
    pub fn label(self) -> &'static str {
        match self {
            Self::FiveHour => "5-hour",
            Self::SevenDay => "Weekly",
            Self::Opus => "Opus weekly",
        }
    }
}

impl QuotaLimits {
    /// The API answered without a single window: a plan with no limits of
    /// this kind, rather than a failed fetch.
    pub fn is_empty(&self) -> bool {
        self.five_hour.is_none() && self.seven_day.is_none() && self.seven_day_opus.is_none()
    }

    /// The windows the menu bar has been asked for, shortest first, skipping any
    /// the API did not report. Shared by the title and the dropdown so the two
    /// always agree on what is being shown.
    pub fn shown(&self, display: &MenuBarSettings) -> Vec<(QuotaKind, &QuotaWindow)> {
        [
            (
                QuotaKind::FiveHour,
                self.five_hour.as_ref(),
                display.show_five_hour,
            ),
            (
                QuotaKind::SevenDay,
                self.seven_day.as_ref(),
                display.show_seven_day,
            ),
        ]
        .into_iter()
        .filter(|(_, _, shown)| *shown)
        .filter_map(|(kind, window, _)| window.map(|window| (kind, window)))
        .collect()
    }
}

#[derive(Deserialize)]
struct OauthUsage {
    #[serde(default)]
    five_hour: Option<RawWindow>,
    #[serde(default)]
    seven_day: Option<RawWindow>,
    #[serde(default)]
    seven_day_opus: Option<RawWindow>,
}

#[derive(Deserialize)]
struct RawWindow {
    #[serde(default)]
    utilization: Option<f64>,
    #[serde(default)]
    resets_at: Option<Value>,
    #[serde(default)]
    used_dollars: Option<f64>,
    #[serde(default)]
    limit_dollars: Option<f64>,
}

/// The parts of Claude Code's stored login this app reads.
struct Credentials {
    token: String,
    expires_at: Option<DateTime<Utc>>,
    subscription_type: Option<String>,
    rate_limit_tier: Option<String>,
}

impl Credentials {
    fn bare(token: String) -> Self {
        Self {
            token,
            expires_at: None,
            subscription_type: None,
            rate_limit_tier: None,
        }
    }

    fn is_expired(&self, now: DateTime<Utc>) -> bool {
        self.expires_at.is_some_and(|expires_at| expires_at <= now)
    }
}

pub fn fetch_quota_limits() -> Result<QuotaLimits, String> {
    let credentials = load_credentials()?;
    // Checked here rather than left to the API, whose 401 would read as signed
    // out. Claude Code swaps in a new token the next time it runs, and the next
    // poll picks that up from the keychain.
    if credentials.is_expired(Utc::now()) {
        return Err(EXPIRED_TOKEN.into());
    }
    let response = agent()
        .get(USAGE_URL)
        .set("Authorization", &format!("Bearer {}", credentials.token))
        .set("anthropic-beta", OAUTH_BETA)
        .set("Accept", "application/json")
        .set("User-Agent", claude_user_agent())
        .call()
        .map_err(http_error)?;

    let status = response.status();
    let body = response.into_string().map_err(|err| err.to_string())?;
    if !(200..300).contains(&status) {
        return Err(status_error(status));
    }

    let parsed: OauthUsage =
        serde_json::from_str(&body).map_err(|err| format!("usage API JSON: {err}"))?;
    Ok(QuotaLimits {
        five_hour: parsed.five_hour.and_then(parse_window),
        seven_day: parsed.seven_day.and_then(parse_window),
        seven_day_opus: parsed.seven_day_opus.and_then(parse_window),
    })
}

/// `claude auth status` can still report logged in when the keychain item is
/// sitting there with an expired or revoked access token. The usage endpoint
/// answering 401, or there being nothing to send, is the session actually
/// ending; callers should drop cached numbers and show the signed-out state.
pub fn is_unauthorized(err: &str) -> bool {
    is_missing_token(err) || err.ends_with("HTTP 401")
}

/// The token is there but past its expiry. Still logged in: Claude Code
/// refreshes it on its next run, so this is not the signed-out state.
pub fn is_expired(err: &str) -> bool {
    err == EXPIRED_TOKEN
}

/// The plan named in the stored login, e.g. `Max 20x`. Read whatever the
/// token's expiry, since the plan does not lapse with it.
pub fn subscription_plan() -> Option<String> {
    let credentials = load_credentials().ok()?;
    account::plan_name(
        credentials.subscription_type.as_deref(),
        credentials.rate_limit_tier.as_deref(),
        seat_tier().as_deref(),
    )
}

/// Team and Enterprise seats are only named in the profile Claude Code caches.
fn seat_tier() -> Option<String> {
    let text = std::fs::read_to_string(home_join(PROFILE_FILE)?).ok()?;
    let value = serde_json::from_str::<Value>(&text).ok()?;
    value
        .get("oauthAccount")?
        .get("seatTier")?
        .as_str()
        .map(str::to_string)
}

/// Nothing to send at all, as opposed to a token the API turned down. Only
/// this case needs the CLI looked for, to tell signed out from not installed.
pub fn is_missing_token(err: &str) -> bool {
    err == MISSING_TOKEN
}

fn parse_window(raw: RawWindow) -> Option<QuotaWindow> {
    // Each window also carries dollar figures. Where only those are filled in,
    // the share of the limit spent is the same number utilization would be.
    let used = raw
        .utilization
        .or_else(|| match (raw.used_dollars, raw.limit_dollars) {
            (Some(used), Some(limit)) if limit > 0.0 => Some(used / limit * FULL_PERCENT),
            _ => None,
        })?;
    Some(QuotaWindow {
        used,
        remaining: (FULL_PERCENT - used).clamp(0.0, FULL_PERCENT),
        resets_at: raw.resets_at.as_ref().and_then(parse_reset),
    })
}

/// `resets_at` comes back as an RFC 3339 string on some plans and as epoch
/// seconds on others.
fn parse_reset(value: &Value) -> Option<DateTime<Utc>> {
    match value {
        Value::String(text) => DateTime::parse_from_rfc3339(text)
            .ok()
            .map(|dt| dt.with_timezone(&Utc)),
        Value::Number(number) => number
            .as_i64()
            .or_else(|| number.as_f64().map(|secs| secs as i64))
            .and_then(|secs| DateTime::from_timestamp(secs, 0)),
        _ => None,
    }
}

/// Claude Code keeps the token in the login keychain on macOS and in a JSON file
/// elsewhere, and either can be overridden by the environment.
fn load_credentials() -> Result<Credentials, String> {
    if let Ok(token) = std::env::var(TOKEN_ENV) {
        let token = token.trim().to_string();
        if !token.is_empty() {
            return Ok(Credentials::bare(token));
        }
    }

    if let Some(credentials) = credentials_from_keychain() {
        return Ok(credentials);
    }

    for path in CREDENTIAL_FILES.iter().filter_map(|file| home_join(file)) {
        if let Ok(text) = std::fs::read_to_string(&path)
            && let Ok(value) = serde_json::from_str::<Value>(&text)
            && let Some(credentials) = credentials_from_json(&value)
        {
            return Ok(credentials);
        }
    }

    Err(MISSING_TOKEN.into())
}

fn credentials_from_keychain() -> Option<Credentials> {
    let output = Command::new("security")
        .args(["find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let raw = String::from_utf8(output.stdout).ok()?;
    let value = serde_json::from_str::<Value>(raw.trim()).ok()?;
    credentials_from_json(&value)
}

/// The key has moved between Claude Code versions, so try each nesting and then
/// the top level. The expiry and plan are read from whichever one holds the token.
fn credentials_from_json(value: &Value) -> Option<Credentials> {
    let candidates = [
        value.get("claudeAiOauth"),
        value.get("claude_ai_oauth"),
        value.get("oauth"),
        Some(value),
    ];
    for candidate in candidates.into_iter().flatten() {
        let Some(token) = candidate.get("accessToken").and_then(Value::as_str) else {
            continue;
        };
        let token = token.trim();
        if token.is_empty() {
            continue;
        }
        let text = |key: &str| {
            candidate
                .get(key)
                .and_then(Value::as_str)
                .map(str::to_string)
        };
        return Some(Credentials {
            token: token.to_string(),
            // Epoch milliseconds.
            expires_at: candidate
                .get("expiresAt")
                .and_then(Value::as_i64)
                .and_then(DateTime::from_timestamp_millis),
            subscription_type: text("subscriptionType"),
            rate_limit_tier: text("rateLimitTier"),
        });
    }
    None
}

/// One agent for the life of the process, so the poll a minute from now reuses
/// the pooled connection instead of paying for another TLS handshake.
fn agent() -> &'static ureq::Agent {
    static AGENT: OnceLock<ureq::Agent> = OnceLock::new();
    AGENT.get_or_init(|| ureq::AgentBuilder::new().timeout(REQUEST_TIMEOUT).build())
}

/// The installed CLI's version, as the endpoint expects to see it.
///
/// Worked out once and kept: reading it can cost a shell start and a Node
/// start, which is far too much to repeat on every poll. Upgrading Claude Code
/// while this is running leaves the agent one version behind until the next
/// restart, and the endpoint only cares that the version is plausible.
fn claude_user_agent() -> &'static str {
    static USER_AGENT: OnceLock<String> = OnceLock::new();
    USER_AGENT.get_or_init(|| {
        let version = cli::locate()
            .and_then(|binary| cli::version(&binary))
            .unwrap_or_else(|| FALLBACK_CLI_VERSION.into());
        format!("claude-code/{version}")
    })
}

fn http_error(err: ureq::Error) -> String {
    match err {
        ureq::Error::Status(code, _) => status_error(code),
        ureq::Error::Transport(transport) => format!("Usage API: {transport}"),
    }
}

fn status_error(status: u16) -> String {
    format!("Usage API returned HTTP {status}")
}

fn home_join(relative: &str) -> Option<std::path::PathBuf> {
    std::env::var_os("HOME").map(|home| std::path::PathBuf::from(home).join(relative))
}

impl QuotaWindow {
    pub fn timing_label(&self, kind: QuotaKind) -> String {
        let Some(resets_at) = self.resets_at else {
            return match kind {
                QuotaKind::FiveHour => "Starts when you send a message",
                QuotaKind::SevenDay | QuotaKind::Opus => "Reset time unknown",
            }
            .into();
        };
        let now = Utc::now();
        if resets_at <= now {
            return "Reset due".into();
        }
        let remaining = resets_at - now;
        format!("Resets in {}", format_duration(remaining, " "))
    }

    /// The bare figure, in whichever direction was asked for.
    pub fn percent(&self, mode: PercentMode) -> f64 {
        match mode {
            PercentMode::Left => self.remaining,
            PercentMode::Used => self.used,
        }
    }

    /// `62% left` or `38% used`, for anywhere with room for the word.
    pub fn percent_label(&self, mode: PercentMode) -> String {
        match mode {
            PercentMode::Left => format!("{:.0}% left", self.remaining),
            PercentMode::Used => format!("{:.0}% used", self.used),
        }
    }

    /// `2h41m`, for the menu bar, where `timing_label`'s wording would not fit.
    /// `None` when the API did not say when the window turns over.
    pub fn countdown_label(&self) -> Option<String> {
        let resets_at = self.resets_at?;
        let remaining = resets_at - Utc::now();
        if remaining <= Duration::zero() {
            return Some("due".into());
        }
        Some(format_duration(remaining, ""))
    }
}

/// The separator is what tells the two callers apart: the window and the
/// dropdown read `2h 41m`, the menu bar packs it to `2h41m`.
fn format_duration(duration: Duration, separator: &str) -> String {
    let minutes = duration.num_minutes().max(0);
    let days = minutes / (60 * 24);
    let hours = (minutes / 60) % 24;
    let mins = minutes % 60;
    if days > 0 {
        format!("{days}d{separator}{hours}h")
    } else if hours > 0 {
        format!("{hours}h{separator}{mins}m")
    } else {
        format!("{mins}m")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unauthorized_is_a_dead_token_not_a_failed_refresh() {
        assert!(is_unauthorized(MISSING_TOKEN));
        assert!(is_unauthorized("Usage API returned HTTP 401"));
        assert!(!is_unauthorized("Usage API returned HTTP 500"));
        assert!(!is_unauthorized("Usage API: connection reset"));
    }

    #[test]
    fn an_expired_token_is_not_a_signed_out_one() {
        assert!(is_expired(EXPIRED_TOKEN));
        assert!(!is_unauthorized(EXPIRED_TOKEN));
        assert!(!is_missing_token(EXPIRED_TOKEN));
    }

    #[test]
    fn the_stored_login_carries_its_expiry_and_plan() {
        let value = serde_json::json!({
            "claudeAiOauth": {
                "accessToken": " token ",
                "expiresAt": 1_790_153_332_424_i64,
                "subscriptionType": "max",
                "rateLimitTier": "default_claude_max_20x"
            }
        });
        let credentials = credentials_from_json(&value).unwrap();
        assert_eq!(credentials.token, "token");
        assert_eq!(credentials.subscription_type.as_deref(), Some("max"));
        assert_eq!(
            credentials.rate_limit_tier.as_deref(),
            Some("default_claude_max_20x")
        );
        let expires_at = credentials.expires_at.unwrap();
        assert_eq!(expires_at.timestamp_millis(), 1_790_153_332_424);
        assert!(credentials.is_expired(expires_at));
        assert!(!credentials.is_expired(expires_at - Duration::seconds(1)));
    }

    #[test]
    fn a_token_with_no_expiry_is_never_called_expired() {
        let value = serde_json::json!({ "accessToken": "token" });
        let credentials = credentials_from_json(&value).unwrap();
        assert!(!credentials.is_expired(Utc::now()));
    }

    #[test]
    fn a_window_reported_only_in_dollars_still_has_a_figure() {
        let raw: RawWindow = serde_json::from_value(serde_json::json!({
            "utilization": null, "used_dollars": 25.0, "limit_dollars": 100.0, "resets_at": null
        }))
        .unwrap();
        let window = parse_window(raw).unwrap();
        assert_eq!(window.used, 25.0);
        assert_eq!(window.remaining, 75.0);

        let raw: RawWindow = serde_json::from_value(serde_json::json!({
            "utilization": null, "used_dollars": null, "limit_dollars": null
        }))
        .unwrap();
        assert!(parse_window(raw).is_none());
    }

    #[test]
    fn only_a_missing_token_sends_the_app_looking_for_the_cli() {
        assert!(is_missing_token(MISSING_TOKEN));
        assert!(!is_missing_token("Usage API returned HTTP 401"));
    }

    #[test]
    fn an_unopened_five_hour_window_explains_when_it_starts() {
        let window = QuotaWindow {
            used: 0.0,
            remaining: 100.0,
            resets_at: None,
        };

        assert_eq!(
            window.timing_label(QuotaKind::FiveHour),
            "Starts when you send a message"
        );
        assert_eq!(
            window.timing_label(QuotaKind::SevenDay),
            "Reset time unknown"
        );
    }
}
