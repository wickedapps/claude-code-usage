use crate::auth::{self, Auth};
use crate::limits;
use crate::usage::{self, UsageSnapshot};

pub enum Session {
    NotInstalled,
    LoggedOut,
    LoggedIn(Box<UsageSnapshot>),
}

pub fn load() -> Result<Session, String> {
    match auth::check()? {
        Auth::NotInstalled => Ok(Session::NotInstalled),
        Auth::LoggedOut => Ok(Session::LoggedOut),
        Auth::LoggedIn => {
            let snapshot = usage::load_usage();
            // The CLI reports logged in from a keychain item that can outlive
            // the token. A 401 from the usage API is the real session ending.
            if snapshot
                .limits
                .as_ref()
                .err()
                .is_some_and(|err| limits::is_unauthorized(err))
            {
                Ok(Session::LoggedOut)
            } else {
                Ok(Session::LoggedIn(Box::new(snapshot)))
            }
        }
    }
}
