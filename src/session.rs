use crate::account::{self, ApiBilling};
use crate::cli;
use crate::limits;
use crate::usage::{self, UsageReport, UsageSnapshot};

pub enum Session {
    NotInstalled,
    LoggedOut,
    /// On a subscription, or at least not known to be off one. `plan` is its
    /// name when the stored login says.
    LoggedIn {
        plan: Option<String>,
        snapshot: Box<UsageSnapshot>,
    },
    /// Billed per token, so there are no plan limits to fetch. The transcripts
    /// are all there is to show, and for this setup they are the useful part.
    Api {
        billing: ApiBilling,
        report: Result<UsageReport, String>,
    },
}

/// The OAuth token is what the app runs on, so signed in or out is decided by
/// it rather than by `claude auth status`, which reports logged in from a
/// keychain item that can outlive the token. What `claude auth status` is
/// asked is narrower: whether Claude Code is billed per token, which no token
/// in the keychain can say. An API key in the environment outranks a claude.ai
/// login that is still sitting there.
pub fn load() -> Session {
    let binary = cli::locate();
    if let Some(billing) = binary.as_deref().and_then(api_billing_for) {
        return Session::Api {
            billing,
            report: usage::load_transcripts(),
        };
    }

    let snapshot = usage::load_usage();
    match &snapshot.limits {
        Err(err) if limits::is_missing_token(err) => {
            if binary.is_some() {
                Session::LoggedOut
            } else {
                Session::NotInstalled
            }
        }
        // A 401 from the usage API is the real session ending.
        Err(err) if limits::is_unauthorized(err) => Session::LoggedOut,
        _ => Session::LoggedIn {
            plan: limits::subscription_plan(),
            snapshot: Box::new(snapshot),
        },
    }
}

/// Just the billing question, for a poll that wants to notice a switch off
/// the API without rescanning every transcript.
pub fn api_billing() -> Option<ApiBilling> {
    cli::locate().as_deref().and_then(api_billing_for)
}

fn api_billing_for(binary: &std::path::Path) -> Option<ApiBilling> {
    let status = cli::auth_status(binary)?;
    account::api_billing(&status, cli::has_gateway_token())
}
