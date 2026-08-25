//! The one copy of the numbers, shared by the menu bar and the window. It is an
//! app global rather than window state because the menu bar has to keep
//! reporting while the window is closed.

use crate::limits::{self, QuotaLimits};
use crate::session::{self, Session};
use crate::usage::UsageReport;
use gpui::prelude::*;
use gpui::{App, Context, Entity, Global, SharedString};
use std::time::Duration;

/// How often the limits are re-checked with the window open. Ticks hit the OAuth
/// endpoint only; rescanning every transcript this often would be a lot of work
/// for figures nobody is looking at unless the window is up.
const ACTIVE_POLL: Duration = Duration::from_secs(60);
/// The same, with only the menu bar showing. Nothing here is being read closely,
/// and the 5-hour window moves slowly enough that five minutes is no worse.
const PARKED_POLL: Duration = Duration::from_secs(300);

pub struct UsageStore {
    pub loading: bool,
    pub logged_in: Option<bool>,
    pub usage: Option<UsageReport>,
    pub limits: Option<QuotaLimits>,
    pub usage_error: Option<SharedString>,
    pub limits_error: Option<SharedString>,
    pub auth_error: Option<SharedString>,
    /// Only sets the polling rate. The window keeps its own state.
    window_open: bool,
}

impl Default for UsageStore {
    fn default() -> Self {
        Self {
            loading: false,
            logged_in: None,
            usage: None,
            limits: None,
            usage_error: None,
            limits_error: None,
            auth_error: None,
            // The window opens straight after the store is built.
            window_open: true,
        }
    }
}

struct GlobalUsageStore(Entity<UsageStore>);

impl Global for GlobalUsageStore {}

/// What a poll tick should do, decided while the store is borrowed so the fetch
/// itself can run without holding it.
enum Tick {
    Skip,
    Limits,
    Full,
}

impl UsageStore {
    /// Creates the store, starts the first load, and leaves the poll loop
    /// running for the life of the process.
    pub fn init(cx: &mut App) -> Entity<Self> {
        let store = cx.new(|cx| {
            let mut this = Self::default();
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

    /// Everything: the login check, the transcript scan, and the limits.
    pub fn reload(&mut self, cx: &mut Context<Self>) {
        if self.loading {
            return;
        }

        self.loading = true;
        self.auth_error = None;
        cx.notify();

        cx.spawn(async move |this, cx| {
            let result = cx.background_spawn(async { session::load() }).await;
            this.update(cx, |this, cx| {
                this.loading = false;
                this.apply_session(result);
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    fn apply_session(&mut self, result: Result<Session, String>) {
        match result {
            Ok(session) if !session.logged_in => self.sign_out(),
            Ok(session) => {
                self.logged_in = Some(true);
                if let Some(snapshot) = session.snapshot {
                    match snapshot.report {
                        Ok(report) => {
                            self.usage = Some(report);
                            self.usage_error = None;
                        }
                        Err(err) => {
                            self.usage = None;
                            self.usage_error = Some(err.into());
                        }
                    }
                    self.apply_limits(snapshot.limits);
                }
            }
            Err(err) => {
                self.auth_error = Some(err.into());
            }
        }
    }

    fn apply_limits(&mut self, result: Result<QuotaLimits, String>) {
        match result {
            Ok(limits) => {
                self.limits = Some(limits);
                self.limits_error = None;
            }
            Err(err) if limits::is_unauthorized(&err) => self.sign_out(),
            Err(err) => {
                // Dropped rather than left stale, so neither the window nor the
                // menu bar shows a number the API has stopped standing behind.
                self.limits = None;
                self.limits_error = Some(err.into());
            }
        }
    }

    fn sign_out(&mut self) {
        self.logged_in = Some(false);
        self.usage = None;
        self.limits = None;
        self.usage_error = None;
        self.limits_error = None;
        self.auth_error = None;
    }

    /// Keeps the menu bar current. A tick normally fetches only the limits, but
    /// falls back to a full load while signed out so that logging in elsewhere
    /// is picked up without touching the app.
    fn poll(&self, cx: &mut Context<Self>) {
        cx.spawn(async move |this, cx| {
            loop {
                let interval = this.update(cx, |this, _| {
                    if this.window_open {
                        ACTIVE_POLL
                    } else {
                        PARKED_POLL
                    }
                });
                let Ok(interval) = interval else { return };
                cx.background_executor().timer(interval).await;

                let tick = this.update(cx, |this, _| {
                    if this.loading {
                        Tick::Skip
                    } else if this.logged_in == Some(true) {
                        Tick::Limits
                    } else {
                        Tick::Full
                    }
                });
                // The store is gone, which only happens on the way out.
                let Ok(tick) = tick else { return };

                match tick {
                    Tick::Skip => {}
                    Tick::Full => {
                        if this.update(cx, |this, cx| this.reload(cx)).is_err() {
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
        self.loading && self.logged_in.is_none() && self.auth_error.is_none()
    }

    /// The tables and quota cards belong to a live session, not leftover
    /// numbers from a token the API has already rejected.
    pub fn has_dashboard(&self) -> bool {
        self.logged_in == Some(true)
    }
}
