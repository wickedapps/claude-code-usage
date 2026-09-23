//! The one copy of the numbers, shared by the menu bar and the window. It is an
//! app global rather than window state because the menu bar has to keep
//! reporting while the window is closed.

use crate::account::Account;
use crate::limits::{self, QuotaLimits};
use crate::session::{self, Session};
use crate::settings::SettingsStore;
use crate::usage::UsageReport;
use chrono::{DateTime, Utc};
use gpui::prelude::*;
use gpui::{App, Context, Entity, Global, SharedString};
use std::time::Duration;

/// How often the limits are re-checked with the window open. Ticks hit the OAuth
/// endpoint only; rescanning every transcript this often would be a lot of work
/// for figures nobody is looking at unless the window is up. Not a setting: a
/// window on screen is a window being watched.
const ACTIVE_POLL: Duration = Duration::from_secs(60);
/// How often the loop wakes. With only the menu bar showing the interval is the
/// user's to pick, and waiting the whole of it in one sleep would mean a change
/// from fifteen minutes down to one took fifteen minutes to notice. Waking on
/// this cadence and counting up to the interval instead costs a comparison a
/// minute and takes hold within one.
const POLL_TICK: Duration = Duration::from_secs(60);

#[derive(Default)]
pub struct UsageStore {
    pub loading: bool,
    pub cli_installed: Option<bool>,
    pub logged_in: Option<bool>,
    /// How Claude Code is paid for, as of the last full load. `None` until one
    /// lands, and whenever there is no session to describe.
    pub account: Option<Account>,
    /// The stored token is past its expiry. Still logged in, with the limits
    /// held back until Claude Code runs and swaps in a fresh one.
    pub token_expired: bool,
    pub usage: Option<UsageReport>,
    pub limits: Option<QuotaLimits>,
    /// When the API last accepted the limits now in `limits`. The widget uses
    /// this instead of the file-write time, so an unchanged settings write does
    /// not pretend the quota figures were fetched again.
    pub limits_updated_at: Option<DateTime<Utc>>,
    pub usage_error: Option<SharedString>,
    pub limits_error: Option<SharedString>,
    /// Only sets the polling rate. The window keeps its own state. `init` gives
    /// it its real value: the settings can ask for a launch that puts no window
    /// on screen at all, so a default of false is the honest one.
    window_open: bool,
}

struct GlobalUsageStore(Entity<UsageStore>);

impl Global for GlobalUsageStore {}

/// What a poll tick should do, decided while the store is borrowed so the fetch
/// itself can run without holding it.
enum Tick {
    Skip,
    Limits,
    /// Billed per token: there are no limits to fetch, only a switch back to
    /// the subscription to watch for.
    Account,
    Full,
}

impl UsageStore {
    /// Creates the store, starts the first load, and leaves the poll loop
    /// running for the life of the process. `window_open` is whether a window is
    /// going up with it, which only sets the polling rate.
    pub fn init(window_open: bool, cx: &mut App) -> Entity<Self> {
        let store = cx.new(|cx| {
            let mut this = Self {
                window_open,
                ..Self::default()
            };
            this.reload(cx);
            this.poll(cx);
            this
        });
        cx.set_global(GlobalUsageStore(store.clone()));
        store
    }

    pub fn global(cx: &App) -> Entity<Self> {
        cx.global::<GlobalUsageStore>().0.clone()
    }

    /// Does not notify: the window state it reflects has already been applied,
    /// and a redraw of a window on its way off screen is wasted work.
    pub fn set_window_open(&mut self, open: bool) {
        self.window_open = open;
    }

    pub fn window_open(&self) -> bool {
        self.window_open
    }

    /// Everything: the limits, the transcript scan, and, without a token, the
    /// search for the CLI.
    pub fn reload(&mut self, cx: &mut Context<Self>) {
        if self.loading {
            return;
        }

        self.loading = true;
        cx.notify();

        cx.spawn(async move |this, cx| {
            let session = cx.background_spawn(async { session::load() }).await;
            this.update(cx, |this, cx| {
                this.loading = false;
                this.apply_session(session);
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    fn apply_session(&mut self, session: Session) {
        match session {
            Session::NotInstalled => self.cli_not_installed(),
            Session::LoggedOut => self.sign_out(),
            Session::LoggedIn { plan, snapshot } => {
                self.cli_installed = Some(true);
                self.logged_in = Some(true);
                self.account = Some(Account::Subscription { plan });
                self.apply_report(snapshot.report);
                self.apply_limits(snapshot.limits);
            }
            Session::Api { billing, report } => {
                self.cli_installed = Some(true);
                self.logged_in = Some(true);
                self.account = Some(Account::Api(billing));
                self.token_expired = false;
                self.limits = None;
                self.limits_updated_at = None;
                self.limits_error = None;
                self.apply_report(report);
            }
        }
    }

    fn apply_report(&mut self, report: Result<UsageReport, String>) {
        match report {
            Ok(report) => {
                self.usage = Some(report);
                self.usage_error = None;
            }
            Err(err) => {
                self.usage = None;
                self.usage_error = Some(err.into());
            }
        }
    }

    fn apply_limits(&mut self, result: Result<QuotaLimits, String>) {
        match result {
            Ok(limits) => {
                self.limits = Some(limits);
                self.limits_updated_at = Some(Utc::now());
                self.limits_error = None;
                self.token_expired = false;
            }
            Err(err) if limits::is_unauthorized(&err) => self.sign_out(),
            // Not an error to show in red: nothing is wrong that running Claude
            // Code will not fix, and the window says as much.
            Err(err) if limits::is_expired(&err) => {
                self.limits = None;
                self.limits_updated_at = None;
                self.limits_error = None;
                self.token_expired = true;
            }
            Err(err) => {
                self.token_expired = false;
                // Dropped rather than left stale, so neither the window nor the
                // menu bar shows a number the API has stopped standing behind.
                self.limits = None;
                self.limits_updated_at = None;
                self.limits_error = Some(err.into());
            }
        }
    }

    fn sign_out(&mut self) {
        self.cli_installed = Some(true);
        self.logged_in = Some(false);
        self.account = None;
        self.token_expired = false;
        self.usage = None;
        self.limits = None;
        self.limits_updated_at = None;
        self.usage_error = None;
        self.limits_error = None;
    }

    fn cli_not_installed(&mut self) {
        self.cli_installed = Some(false);
        self.logged_in = None;
        self.account = None;
        self.token_expired = false;
        self.usage = None;
        self.limits = None;
        self.limits_updated_at = None;
        self.usage_error = None;
        self.limits_error = None;
    }

    /// Keeps the menu bar current. A tick normally fetches only the limits, but
    /// falls back to a full load while signed out so that logging in elsewhere
    /// is picked up without touching the app. Billed per token, it only asks
    /// whether that is still so, and reloads once it is not.
    fn poll(&self, cx: &mut Context<Self>) {
        cx.spawn(async move |this, cx| {
            let mut waited = Duration::ZERO;
            loop {
                cx.background_executor().timer(POLL_TICK).await;
                waited += POLL_TICK;

                let due = this.update(cx, |this, cx| {
                    let interval = if this.window_open {
                        ACTIVE_POLL
                    } else {
                        SettingsStore::get(cx).refresh.interval()
                    };
                    waited >= interval
                });
                // The store is gone, which only happens on the way out.
                let Ok(due) = due else { return };
                if !due {
                    continue;
                }
                waited = Duration::ZERO;

                let tick = this.update(cx, |this, _| {
                    if this.loading {
                        Tick::Skip
                    } else if matches!(this.account, Some(Account::Api(_))) {
                        Tick::Account
                    } else if this.logged_in == Some(true) {
                        Tick::Limits
                    } else {
                        Tick::Full
                    }
                });
                let Ok(tick) = tick else { return };

                match tick {
                    Tick::Skip => {}
                    Tick::Full => {
                        if this.update(cx, |this, cx| this.reload(cx)).is_err() {
                            return;
                        }
                    }
                    Tick::Account => {
                        let billing = cx.background_spawn(async { session::api_billing() }).await;
                        let reloaded = this.update(cx, |this, cx| {
                            if this.account != billing.map(Account::Api) {
                                this.reload(cx);
                            }
                        });
                        if reloaded.is_err() {
                            return;
                        }
                    }
                    Tick::Limits => {
                        let result = cx
                            .background_spawn(async { limits::fetch_quota_limits() })
                            .await;
                        let applied = this.update(cx, |this, cx| {
                            this.apply_limits(result);
                            cx.notify();
                        });
                        if applied.is_err() {
                            return;
                        }
                    }
                }
            }
        })
        .detach();
    }

    /// Only the very first load takes over the window with a spinner. Later
    /// refreshes keep the numbers on screen and spin the header button instead.
    pub fn is_initial_load(&self) -> bool {
        self.loading && self.logged_in.is_none() && self.cli_installed.is_none()
    }

    /// The tables and quota cards belong to a live session, not leftover
    /// numbers from a token the API has already rejected.
    pub fn has_dashboard(&self) -> bool {
        self.logged_in == Some(true)
    }
}
