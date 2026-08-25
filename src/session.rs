use crate::auth::{self, Auth};
use crate::limits;
use crate::usage::{self, UsageSnapshot};

pub struct Session {
    pub logged_in: bool,
    pub snapshot: Option<UsageSnapshot>,
}

pub fn load() -> Result<Session, String> {
    match auth::check()? {
        Auth::LoggedOut => Ok(Session {
            logged_in: false,
            snapshot: None,
        }),
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
                Ok(Session {
                    logged_in: false,
                    snapshot: None,
                })
            } else {
                Ok(Session {
                    logged_in: true,
                    snapshot: Some(snapshot),
                })
            }
        }
    }
}
