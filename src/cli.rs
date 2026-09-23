//! Finding the `claude` binary from a GUI process.
//!
//! An app started from Finder or at login inherits launchd's PATH, which holds
//! none of the directories Claude Code installs into. A login shell alone does
//! not fix that: `zsh -l` reads `.zprofile` but not `.zshrc`, and Homebrew is
//! the only installer that writes to `.zprofile`. The native installer, npm under
//! nvm, bun, pnpm, and mise all add themselves in `.zshrc`. So the PATH comes
//! from an interactive login shell, and the usual install directories back it up
//! for anyone whose shell cannot be run that way.
//!
//! The same shell also supplies the variables that decide how Claude Code
//! authenticates. An API key exported in `.zshrc` is invisible to a Finder
//! launch, and `claude auth status` run without it would report the
//! subscription a terminal is not actually using.

use std::ffi::OsString;
use std::io::{BufRead, BufReader};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{OnceLock, mpsc};
use std::time::Duration;

const BINARY: &str = "claude";
const FALLBACK_SHELL: &str = "/bin/zsh";
const PATH_START: &str = "__CLAUDE_USAGE_PATH_START__";
const PATH_END: &str = "__CLAUDE_USAGE_PATH_END__";
/// Variables Claude Code reads to pick how it authenticates, passed on to
/// `claude auth status` so it answers for the setup a terminal has. Values are
/// only ever handed to that child, never logged or shown.
const AUTH_ENV: [&str; 7] = [
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "CLAUDE_CODE_OAUTH_TOKEN",
    "CLAUDE_CODE_USE_BEDROCK",
    "CLAUDE_CODE_USE_VERTEX",
    "CLAUDE_CODE_USE_FOUNDRY",
    "CLAUDE_CONFIG_DIR",
];
const GATEWAY_TOKEN_ENV: &str = "ANTHROPIC_AUTH_TOKEN";
const SETUP_TOKEN_ENV: &str = "CLAUDE_CODE_OAUTH_TOKEN";
/// An interactive shell runs everything in the user's rc files, some of which
/// can wait on the network or on a prompt nobody will answer.
const SHELL_TIMEOUT: Duration = Duration::from_secs(5);
const LAUNCHCTL_TIMEOUT: Duration = Duration::from_secs(2);
const VERSION_TIMEOUT: Duration = Duration::from_secs(4);
/// `claude auth status` answers from local state in about a tenth of a second.
const AUTH_STATUS_TIMEOUT: Duration = Duration::from_secs(5);
/// Where installers put `claude`, relative to `$HOME`. Checked after the shell's
/// PATH, so an install made while the app is running is still found.
const HOME_INSTALL_DIRS: [&str; 10] = [
    ".local/bin",
    ".claude/local",
    ".bun/bin",
    ".npm-global/bin",
    ".volta/bin",
    "Library/pnpm",
    ".local/share/pnpm",
    ".local/share/mise/shims",
    ".asdf/shims",
    ".yarn/bin",
];
const SYSTEM_INSTALL_DIRS: [&str; 2] = ["/opt/homebrew/bin", "/usr/local/bin"];
/// Each Node version nvm manages has its own global `bin`.
const NVM_VERSIONS_DIR: &str = ".nvm/versions/node";

/// The first `claude` on the search path, or `None` when it is not installed
/// anywhere this can see.
pub fn locate() -> Option<PathBuf> {
    search_dirs()
        .into_iter()
        .map(|dir| dir.join(BINARY))
        .find(|path| is_executable(path))
}

/// Reports the installed CLI's version, picking the first whitespace-separated
/// word that starts with a digit out of `claude --version`.
pub fn version(binary: &Path) -> Option<String> {
    let mut command = Command::new(binary);
    command.arg("--version").env("PATH", search_path());
    let text = run(command, VERSION_TIMEOUT, None)?;
    text.split_whitespace()
        .find(|part| part.chars().next().is_some_and(|ch| ch.is_ascii_digit()))
        .map(|part| {
            part.trim_matches(|ch: char| !ch.is_ascii_digit() && ch != '.')
                .to_string()
        })
        .filter(|version| !version.is_empty())
}

/// `claude auth status --json`, run with the login shell's auth variables.
/// `None` when it could not be run or did not print JSON. Signed out, it still
/// prints its JSON and exits 1, so the exit code is not checked.
pub fn auth_status(binary: &Path) -> Option<serde_json::Value> {
    let mut command = Command::new(binary);
    command
        .args(["auth", "status", "--json"])
        .env("PATH", search_path());
    for (name, value) in &login_env().auth {
        command.env(name, value);
    }
    let text = run(command, AUTH_STATUS_TIMEOUT, None)?;
    serde_json::from_str(text.trim()).ok()
}

/// Whether Claude Code is being handed a gateway's bearer token rather than a
/// subscription's. `claude auth status` says `oauth_token` for both, and only
/// the variable it came from tells them apart.
pub fn has_gateway_token() -> bool {
    let set = |name: &str| {
        login_env().auth.iter().any(|(key, _)| key == name) || std::env::var_os(name).is_some()
    };
    set(GATEWAY_TOKEN_ENV) && !set(SETUP_TOKEN_ENV)
}

/// The PATH to hand a child process. An npm install of `claude` is a script
/// run by `node`, which is only on the user's PATH, not launchd's.
fn search_path() -> OsString {
    std::env::join_paths(search_dirs()).unwrap_or_default()
}

/// The shell's PATH first, since it decides which `claude` a terminal runs,
/// then the one this process inherited, then the usual install directories.
fn search_dirs() -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    for path in [login_env().path.clone(), std::env::var_os("PATH")]
        .into_iter()
        .flatten()
    {
        dirs.extend(std::env::split_paths(&path));
    }
    dirs.extend(install_dirs());

    let mut seen = std::collections::HashSet::new();
    dirs.retain(|dir| !dir.as_os_str().is_empty() && seen.insert(dir.clone()));
    dirs
}

/// What the login shell had set, or `launchctl`'s PATH when there is no shell
/// to ask.
#[derive(Debug, Default, PartialEq)]
struct LoginEnv {
    path: Option<OsString>,
    /// The `AUTH_ENV` variables the shell had set, by name.
    auth: Vec<(String, String)>,
}

/// Read once per run: it costs a shell start and everything in the rc files. A
/// directory added to the rc files later is still covered by `install_dirs`
/// when it is one of the usual ones.
fn login_env() -> &'static LoginEnv {
    static LOGIN_ENV: OnceLock<LoginEnv> = OnceLock::new();
    LOGIN_ENV.get_or_init(|| {
        let mut env = shell_env().unwrap_or_default();
        if env.path.is_none() {
            env.path = launchctl_path();
        }
        env
    })
}

fn shell_env() -> Option<LoginEnv> {
    let shell = std::env::var("SHELL")
        .ok()
        .filter(|shell| !shell.trim().is_empty())
        .unwrap_or_else(|| FALLBACK_SHELL.into());
    let mut command = Command::new(shell);
    command.args(["-ilc", &print_env_command()]);
    let text = run(command, SHELL_TIMEOUT, Some(PATH_END))?;
    parse_marked_env(&text)
}

/// The PATH on the first line and any `AUTH_ENV` variables after it, between
/// markers that keep whatever the rc files print from being read as either.
/// `env | grep` rather than a loop so the same line works in zsh, bash, and fish.
fn print_env_command() -> String {
    format!(
        "printf '%s\\n' '{PATH_START}'; printenv PATH || true; \
         env | grep -E '^({names})=' || true; printf '%s\\n' '{PATH_END}'",
        names = AUTH_ENV.join("|"),
    )
}

fn launchctl_path() -> Option<OsString> {
    let mut command = Command::new("/bin/launchctl");
    command.args(["getenv", "PATH"]);
    let text = run(command, LAUNCHCTL_TIMEOUT, None)?;
    let path = text.trim();
    (!path.is_empty()).then(|| OsString::from(path))
}

fn parse_marked_env(text: &str) -> Option<LoginEnv> {
    let start = text.find(PATH_START)? + PATH_START.len();
    let end = start + text[start..].find(PATH_END)?;
    let mut env = LoginEnv::default();
    for line in text[start..end].lines().map(str::trim) {
        if line.is_empty() {
            continue;
        }
        let variable = line
            .split_once('=')
            .filter(|(name, _)| AUTH_ENV.contains(name));
        match variable {
            Some((name, value)) => env.auth.push((name.into(), value.into())),
            None if env.path.is_none() => env.path = Some(line.into()),
            None => {}
        }
    }
    (env.path.is_some() || !env.auth.is_empty()).then_some(env)
}

fn install_dirs() -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    if let Some(home) = std::env::var_os("HOME").map(PathBuf::from) {
        dirs.extend(HOME_INSTALL_DIRS.iter().map(|dir| home.join(dir)));
        dirs.extend(nvm_bin_dirs(&home.join(NVM_VERSIONS_DIR)));
    }
    dirs.extend(SYSTEM_INSTALL_DIRS.iter().map(PathBuf::from));
    dirs
}

/// Newest-looking version first. Sorted as text rather than as versions, which
/// only matters to someone with `claude` installed under several of them.
fn nvm_bin_dirs(versions: &Path) -> Vec<PathBuf> {
    let Ok(entries) = std::fs::read_dir(versions) else {
        return Vec::new();
    };
    let mut dirs: Vec<PathBuf> = entries
        .flatten()
        .map(|entry| entry.path().join("bin"))
        .collect();
    dirs.sort_by(|a, b| b.cmp(a));
    dirs
}

fn is_executable(path: &Path) -> bool {
    std::fs::metadata(path)
        .is_ok_and(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
}

/// Runs `command` and returns its stdout, giving up after `timeout`. With
/// `until`, stops reading at the first line containing it: an rc file can start
/// a background job that holds the pipe open long after the shell has printed
/// what was asked for.
fn run(mut command: Command, timeout: Duration, until: Option<&'static str>) -> Option<String> {
    let mut child = command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let stdout = child.stdout.take()?;

    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        let mut text = String::new();
        for line in BufReader::new(stdout).lines() {
            let Ok(line) = line else { break };
            let done = until.is_some_and(|marker| line.contains(marker));
            text.push_str(&line);
            text.push('\n');
            if done {
                break;
            }
        }
        sender.send(text).ok();
    });

    let text = receiver.recv_timeout(timeout).ok();
    child.kill().ok();
    child.wait().ok();
    text
}

#[cfg(test)]
mod tests {
    use super::{LoginEnv, PATH_END, PATH_START, parse_marked_env, print_env_command};

    #[test]
    fn the_path_is_read_from_between_the_markers() {
        let text =
            "Last login: today\n__CLAUDE_USAGE_PATH_START__\n/a:/b\n__CLAUDE_USAGE_PATH_END__\n";
        assert_eq!(
            parse_marked_env(text),
            Some(LoginEnv {
                path: Some("/a:/b".into()),
                auth: Vec::new(),
            })
        );
    }

    #[test]
    fn auth_variables_come_after_the_path() {
        let text = "__CLAUDE_USAGE_PATH_START__\n/a:/b\nANTHROPIC_API_KEY=sk-x=y\n\
                    CLAUDE_CODE_USE_BEDROCK=1\n__CLAUDE_USAGE_PATH_END__\n";
        let env = parse_marked_env(text).unwrap();
        assert_eq!(env.path.as_deref(), Some("/a:/b".as_ref()));
        assert_eq!(
            env.auth,
            [
                ("ANTHROPIC_API_KEY".into(), "sk-x=y".into()),
                ("CLAUDE_CODE_USE_BEDROCK".into(), "1".into()),
            ]
        );
    }

    #[test]
    fn rc_noise_without_markers_is_not_a_path() {
        assert_eq!(parse_marked_env("/usr/bin:/bin\n"), None);
        assert_eq!(
            parse_marked_env("__CLAUDE_USAGE_PATH_START__\n__CLAUDE_USAGE_PATH_END__\n"),
            None
        );
    }

    #[test]
    fn the_shell_command_is_bracketed_by_the_markers() {
        let command = print_env_command();
        assert!(command.contains(PATH_START) && command.ends_with(&format!("'{PATH_END}'")));
        assert!(command.contains("ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN"));
    }
}
