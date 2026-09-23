use crate::cli;
use crate::limits;
use crate::usage::{self, UsageSnapshot};

pub enum Session {
    NotInstalled,
    LoggedOut,
    LoggedIn(Box<UsageSnapshot>),
}

/// The OAuth token is what the app runs on, so the session is decided by it
/// rather than by `claude auth status`, which reports logged in from a keychain
/// item that can outlive the token and needs the CLI found and started to say
/// even that. The CLI only matters once there is no token: installed means
/// signed out, and not installed gets its own screen.
pub fn load() -> Session {
    let snapshot = usage::load_usage();
    match &snapshot.limits {
        Err(err) if limits::is_missing_token(err) => {
            if cli::locate().is_some() {
                Session::LoggedOut
            } else {
                Session::NotInstalled
            }
        }
        // A 401 from the usage API is the real session ending.
        Err(err) if limits::is_unauthorized(err) => Session::LoggedOut,
        _ => Session::LoggedIn(Box::new(snapshot)),
    }
}
