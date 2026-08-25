use serde_json::Value;
use std::process::Command;

/// A GUI process inherits launchd's PATH, not the user's, so `claude` is only on
/// PATH once a login shell has sourced their profile.
pub const LOGIN_SHELL: &str = "/bin/zsh";

pub enum Auth {
    LoggedIn,
    LoggedOut,
}

pub fn check() -> Result<Auth, String> {
    let output = Command::new(LOGIN_SHELL)
        .args(["-lc", "claude auth status --json"])
        .output()
        .map_err(|err| format!("Could not run Claude Code: {err}"))?;

    // Older CLI versions print the status JSON on stderr, so search both streams.
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    let combined = [stdout.as_ref(), stderr.as_ref()]
        .into_iter()
        .filter(|part| !part.trim().is_empty())
        .collect::<Vec<_>>()
        .join("\n");

    let json = extract_json(&combined).ok_or_else(|| {
        if combined.trim().is_empty() {
            "Claude Code returned no login status".to_string()
        } else {
            "Could not read Claude login status".to_string()
        }
    })?;

    match json.get("loggedIn").and_then(Value::as_bool) {
        Some(true) => Ok(Auth::LoggedIn),
        Some(false) => Ok(Auth::LoggedOut),
        None => Err("Could not read Claude login status".into()),
    }
}

/// A login shell can print its own noise before the CLI's output, so fall back to
/// the widest brace-delimited span in the text.
fn extract_json(text: &str) -> Option<Value> {
    if let Ok(value) = serde_json::from_str(text) {
        return Some(value);
    }

    let start = text.find('{')?;
    let end = text.rfind('}')?;
    serde_json::from_str(&text[start..=end]).ok()
}
