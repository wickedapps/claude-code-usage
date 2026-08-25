use crate::auth::LOGIN_SHELL;
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
/// Checked in order when the keychain lookup fails, relative to `$HOME`.
const CREDENTIAL_FILES: [&str; 2] = [".claude/.credentials.json", ".claude/credentials.json"];
/// The usage endpoint is OAuth-only and gated behind this beta header.
const OAUTH_BETA: &str = "oauth-2025-04-20";
const REQUEST_TIMEOUT: StdDuration = StdDuration::from_secs(15);
/// Reported when `claude --version` cannot be read. The endpoint rejects
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
}

pub fn fetch_quota_limits() -> Result<QuotaLimits, String> {
    let token = load_access_token()?;
    let response = agent()
        .get(USAGE_URL)
        .set("Authorization", &format!("Bearer {token}"))
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
    err == MISSING_TOKEN || err.ends_with("HTTP 401")
}

fn parse_window(raw: RawWindow) -> Option<QuotaWindow> {
    let used = raw.utilization?;
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
fn load_access_token() -> Result<String, String> {
    if let Ok(token) = std::env::var(TOKEN_ENV) {
        let token = token.trim().to_string();
        if !token.is_empty() {
            return Ok(token);
        }
    }

    if let Some(token) = token_from_keychain() {
        return Ok(token);
    }

    for path in CREDENTIAL_FILES.iter().filter_map(|file| home_join(file)) {
        if let Ok(text) = std::fs::read_to_string(&path)
            && let Ok(value) = serde_json::from_str::<Value>(&text)
            && let Some(token) = token_from_json(&value)
        {
            return Ok(token);
        }
    }

    Err(MISSING_TOKEN.into())
}

fn token_from_keychain() -> Option<String> {
    let output = Command::new("security")
        .args(["find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let raw = String::from_utf8(output.stdout).ok()?;
    let value = serde_json::from_str::<Value>(raw.trim()).ok()?;
    token_from_json(&value)
}

/// The key has moved between Claude Code versions, so try each nesting and then
/// the top level.
fn token_from_json(value: &Value) -> Option<String> {
    let candidates = [
        value.get("claudeAiOauth"),
        value.get("claude_ai_oauth"),
        value.get("oauth"),
        Some(value),
    ];
    for candidate in candidates.into_iter().flatten() {
        if let Some(token) = candidate.get("accessToken").and_then(Value::as_str) {
            let token = token.trim();
            if !token.is_empty() {
                return Some(token.to_string());
            }
        }
    }
    None
}

/// One agent for the life of the process, so the poll a minute from now reuses
/// the pooled connection instead of paying for another TLS handshake.
fn agent() -> &'static ureq::Agent {
    static AGENT: OnceLock<ureq::Agent> = OnceLock::new();
    AGENT.get_or_init(|| ureq::AgentBuilder::new().timeout(REQUEST_TIMEOUT).build())
}

/// Reports the installed CLI's version, picking the first whitespace-separated
/// word that starts with a digit out of `claude --version`.
///
/// Worked out once and kept: reading it costs a login shell and a Node start,
/// which is far too much to repeat on every poll. Upgrading Claude Code while
/// this is running leaves the agent one version behind until the next restart,
/// and the endpoint only cares that the version is plausible.
fn claude_user_agent() -> &'static str {
    static USER_AGENT: OnceLock<String> = OnceLock::new();
    USER_AGENT.get_or_init(|| {
        let version = Command::new(LOGIN_SHELL)
            .args(["-lc", "claude --version"])
            .output()
            .ok()
            .and_then(|output| String::from_utf8(output.stdout).ok())
            .and_then(|text| {
                text.split_whitespace()
                    .find(|part| part.chars().next().is_some_and(|ch| ch.is_ascii_digit()))
                    .map(|part| {
                        part.trim_matches(|ch: char| !ch.is_ascii_digit() && ch != '.')
                            .to_string()
                    })
            })
            .filter(|version| !version.is_empty())
            .unwrap_or_else(|| FALLBACK_CLI_VERSION.into());
        format!("claude-code/{version}")
    })
}

fn http_error(err: ureq::Error) -> String {
    match err {
        ureq::Error::Status(code, _) => status_error(code),
        ureq::Error::Transport(transport) => format!("usage API: {transport}"),
    }
}

fn status_error(status: u16) -> String {
    format!("usage API returned HTTP {status}")
}

fn home_join(relative: &str) -> Option<std::path::PathBuf> {
    std::env::var_os("HOME").map(|home| std::path::PathBuf::from(home).join(relative))
}

impl QuotaWindow {
    pub fn resets_label(&self) -> String {
        let Some(resets_at) = self.resets_at else {
            return "reset time unknown".into();
        };
        let now = Utc::now();
        if resets_at <= now {
            return "reset due".into();
        }
        let remaining = resets_at - now;
        format!("resets in {}", format_duration(remaining))
    }
}

fn format_duration(duration: Duration) -> String {
    let minutes = duration.num_minutes().max(0);
    let days = minutes / (60 * 24);
    let hours = (minutes / 60) % 24;
    let mins = minutes % 60;
    if days > 0 {
        format!("{days}d {hours}h")
    } else if hours > 0 {
        format!("{hours}h {mins}m")
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
        assert!(is_unauthorized("usage API returned HTTP 401"));
        assert!(!is_unauthorized("usage API returned HTTP 500"));
        assert!(!is_unauthorized("usage API: connection reset"));
    }
}
