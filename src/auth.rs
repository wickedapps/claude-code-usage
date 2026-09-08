use serde_json::Value;
use std::process::Command;

/// A GUI process inherits launchd's PATH, not the user's, so `claude` is only on
/// PATH once a login shell has sourced their profile.
pub const LOGIN_SHELL: &str = "/bin/zsh";
const NOT_INSTALLED_MARKER: &str = "__CLAUDE_CODE_NOT_INSTALLED__";
const AUTH_COMMAND: &str = "if command -v claude >/dev/null 2>&1; then claude auth status --json; else printf '\\n__CLAUDE_CODE_NOT_INSTALLED__\\n'; fi";

#[derive(Debug, PartialEq, Eq)]
pub enum Auth {
    NotInstalled,
    LoggedIn,
    LoggedOut,
}

pub fn check() -> Result<Auth, String> {
    let output = Command::new(LOGIN_SHELL)
        .args(["-lc", AUTH_COMMAND])
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

    parse_auth(&combined)
}

fn parse_auth(output: &str) -> Result<Auth, String> {
    if output
        .lines()
        .any(|line| line.trim() == NOT_INSTALLED_MARKER)
    {
        return Ok(Auth::NotInstalled);
    }

    let json = extract_json(output).ok_or_else(|| {
        if output.trim().is_empty() {
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

#[cfg(test)]
mod tests {
    use super::{Auth, parse_auth};

    #[test]
    fn the_missing_cli_marker_gets_its_own_state() {
        assert_eq!(
            parse_auth("profile output\n__CLAUDE_CODE_NOT_INSTALLED__"),
            Ok(Auth::NotInstalled)
        );
    }

    #[test]
    fn valid_status_survives_login_shell_noise() {
        assert_eq!(
            parse_auth("profile output\n{\"loggedIn\":true}"),
            Ok(Auth::LoggedIn)
        );
    }

    #[test]
    fn malformed_cli_output_remains_an_error() {
        assert_eq!(
            parse_auth("unexpected output"),
            Err("Could not read Claude login status".into())
        );
    }
}
