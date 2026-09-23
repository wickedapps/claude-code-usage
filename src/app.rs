use crate::limits::{QuotaKind, QuotaLimits, QuotaWindow};
use crate::login_item::{self, LoginItemStatus};
use crate::settings::{PercentMode, RefreshRate, Settings, SettingsStore};
use crate::store::UsageStore;
use crate::usage::{UsageReport, UsageRow, format_tokens};
use gpui::prelude::*;
use gpui::*;
use gpui_component::button::{Button, ButtonVariants};
use gpui_component::checkbox::Checkbox;
use gpui_component::label::Label;
use gpui_component::progress::Progress;
use gpui_component::radio::RadioGroup;
use gpui_component::scroll::ScrollableElement;
use gpui_component::spinner::Spinner;
use gpui_component::switch::Switch;
use gpui_component::tab::{Tab, TabBar};
use gpui_component::table::{Table, TableBody, TableCell, TableHead, TableHeader, TableRow};
use gpui_component::*;

/// Remaining percentage at or below which a quota bar turns red, then amber.
const DANGER_REMAINING: f64 = 10.0;
const WARNING_REMAINING: f64 = 30.0;
const CLAUDE_CODE_INSTALL_URL: &str = "https://code.claude.com/docs/en/quickstart";

/// Tab labels, in the order the TabBar renders them. `tab_rows` maps the
/// selected index back onto the matching field of the report.
const TABS: [&str; 5] = ["Daily", "Weekly", "Monthly", "Session", "5h Block"];

/// The window shows one of two things. Settings are a pane rather than a second
/// window because GPUI leaks a window's drawables on teardown, which is the same
/// reason this one is parked rather than closed. See `macos::park_window`.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Pane {
    Dashboard,
    Settings,
}

pub struct AppView {
    store: Entity<UsageStore>,
    settings: Entity<SettingsStore>,
    pane: Pane,
    usage_tab: usize,
    /// Read from macOS rather than from the settings file, and only when the
    /// pane opens or a toggle lands: `status` is a trip through AppKit, not a
    /// field to touch on every frame.
    login_item: LoginItemStatus,
    login_error: Option<SharedString>,
    /// Redraws the window whenever the store lands new numbers, including from
    /// a menu bar poll that nobody asked for here.
    _store_observer: Subscription,
    _settings_observer: Subscription,
}

impl AppView {
    pub fn new(_window: &mut Window, cx: &mut Context<Self>) -> Self {
        let store = UsageStore::global(cx);
        let settings = SettingsStore::global(cx);
        let store_observer = cx.observe(&store, |_, store, cx| {
            // Nothing to redraw for while the window is parked, and asking for a
            // frame it will never show costs a CoreAnimation commit and an
            // AppKit display cycle each time. Reopening reloads anyway.
            if !store.read(cx).window_open() {
                return;
            }
            cx.notify();
        });
        // The pane's own controls write through the settings entity, so it is
        // that notify which puts the new state back on screen.
        let settings_observer = cx.observe(&settings, |_, _, cx| cx.notify());
        Self {
            store,
            settings,
            pane: Pane::Dashboard,
            usage_tab: 0,
            login_item: login_item::status(),
            login_error: None,
            _store_observer: store_observer,
            _settings_observer: settings_observer,
        }
    }

    fn reload(&mut self, cx: &mut Context<Self>) {
        self.store.update(cx, |store, cx| store.reload(cx));
    }

    fn show_usage_tab(&mut self, tab: usize, cx: &mut Context<Self>) {
        self.usage_tab = tab;
        cx.notify();
    }

    /// What the status item's Settings… lands on.
    pub fn show_settings(&mut self, cx: &mut Context<Self>) {
        self.pane = Pane::Settings;
        self.login_item = login_item::status();
        cx.notify();
    }

    fn toggle_settings(&mut self, cx: &mut Context<Self>) {
        match self.pane {
            Pane::Dashboard => self.show_settings(cx),
            Pane::Settings => {
                self.pane = Pane::Dashboard;
                cx.notify();
            }
        }
    }

    /// Every write to the settings goes through here, which persists them and
    /// notifies everything watching, the menu bar included.
    fn edit_settings(&mut self, change: impl FnOnce(&mut Settings), cx: &mut Context<Self>) {
        self.settings.update(cx, |store, cx| store.edit(change, cx));
    }

    fn set_login_item(&mut self, enabled: bool, cx: &mut Context<Self>) {
        self.login_error = login_item::set_enabled(enabled).err().map(Into::into);
        // Asked rather than assumed: macOS can register the app and still hold
        // it pending approval, which is not the same as on.
        self.login_item = login_item::status();
        cx.notify();
    }

    fn toggle_menu_bar_window(&mut self, kind: QuotaKind, shown: bool, cx: &mut Context<Self>) {
        self.edit_settings(
            move |settings| {
                let menu_bar = &mut settings.menu_bar;
                match kind {
                    QuotaKind::FiveHour => menu_bar.show_five_hour = shown,
                    QuotaKind::SevenDay => menu_bar.show_seven_day = shown,
                    QuotaKind::Opus => {}
                }
            },
            cx,
        );
    }
}

/// Everything a render needs out of the store, copied out up front so the
/// borrow is over before the listeners below take `cx` mutably.
struct ViewState {
    loading: bool,
    initial_load: bool,
    cli_not_installed: bool,
    logged_out: bool,
    has_dashboard: bool,
    has_usage: bool,
    usage_error: Option<SharedString>,
    limits_error: Option<SharedString>,
    limits: Option<QuotaLimits>,
}

impl From<&UsageStore> for ViewState {
    fn from(store: &UsageStore) -> Self {
        Self {
            loading: store.loading,
            initial_load: store.is_initial_load(),
            cli_not_installed: !store.loading && store.cli_installed == Some(false),
            logged_out: !store.loading && store.logged_in == Some(false),
            has_dashboard: store.has_dashboard(),
            has_usage: store.usage.is_some(),
            usage_error: store.usage_error.clone(),
            limits_error: store.limits_error.clone(),
            limits: store.limits.clone(),
        }
    }
}

impl Render for AppView {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let state = ViewState::from(self.store.read(cx));
        let settings = SettingsStore::get(cx);
        let in_settings = self.pane == Pane::Settings;
        div()
            .id("app-window")
            .size_full()
            .bg(cx.theme().background)
            .overflow_y_scrollbar()
            .child(
                v_flex()
                    .w_full()
                    .when(!in_settings, |this| this.h_full())
                    .p_6()
                    .gap_4()
                    // The settings do not wait on a fetch, and someone who opened the
                    // pane from the menu bar should not be handed a spinner instead.
                    .when(state.initial_load && !in_settings, |this| {
                        this.child(loading_state(cx))
                    })
                    .when(!state.initial_load || in_settings, |this| {
                        this.child(self.render_header(in_settings, state.loading, cx))
                    })
                    .when(in_settings, |this| {
                        this.child(self.render_settings(&settings, cx))
                    })
                    .when(!in_settings, |this| {
                        this.when(state.cli_not_installed, |this| {
                            this.child(cli_not_installed_state(cx))
                        })
                        .when(state.logged_out, |this| this.child(logged_out_state(cx)))
                        .when(state.has_dashboard, |this| {
                            this.child(self.render_dashboard(&state, settings.menu_bar.percent, cx))
                        })
                    }),
            )
    }
}

impl AppView {
    fn render_header(
        &self,
        in_settings: bool,
        loading: bool,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        h_flex()
            .w_full()
            .items_center()
            .justify_between()
            .child(
                h_flex()
                    .items_center()
                    .gap_1()
                    .when(in_settings, |this| {
                        this.child(
                            Button::new("back")
                                .ghost()
                                .compact()
                                .icon(Icon::default().path("icons/arrow-left.svg"))
                                .tooltip("Back")
                                .on_click(cx.listener(|this, _, _, cx| this.toggle_settings(cx))),
                        )
                    })
                    .child(Label::new(if in_settings {
                        "Settings"
                    } else {
                        "Claude Code Usage"
                    })),
            )
            // Nothing on the settings pane is worth a refresh.
            .when(!in_settings, |this| {
                this.child(
                    h_flex()
                        .gap_1()
                        .child(
                            Button::new("refresh")
                                .ghost()
                                .compact()
                                .icon(Icon::default().path("icons/rotate-cw.svg"))
                                .tooltip("Refresh")
                                .loading(loading)
                                .disabled(loading)
                                .on_click(cx.listener(|this, _, _, cx| this.reload(cx))),
                        )
                        .child(
                            Button::new("settings")
                                .ghost()
                                .compact()
                                .icon(Icon::default().path("icons/settings.svg"))
                                .tooltip("Settings")
                                .on_click(cx.listener(|this, _, _, cx| this.toggle_settings(cx))),
                        ),
                )
            })
    }

    fn render_dashboard(
        &self,
        state: &ViewState,
        percent: PercentMode,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        v_flex()
            .flex_1()
            .w_full()
            .gap_4()
            .when_some(state.usage_error.clone(), |this, err| {
                this.child(error_label(err, cx))
            })
            .when_some(state.limits_error.clone(), |this, err| {
                this.child(error_label(err, cx))
            })
            .when_some(state.limits.clone(), |this, limits| {
                this.child(render_quota_limits(&limits, percent, cx))
            })
            .when(state.has_usage, |this| {
                let rows = self
                    .store
                    .read(cx)
                    .usage
                    .as_ref()
                    .map(|report| tab_rows(report, self.usage_tab).to_vec())
                    .unwrap_or_default();
                this.child(
                    TabBar::new("usage-tabs")
                        .w_full()
                        .pill()
                        .selected_index(self.usage_tab)
                        .on_click(cx.listener(|this, ix: &usize, _, cx| {
                            this.show_usage_tab(*ix, cx);
                        }))
                        .children(TABS.map(|label| Tab::new().label(label))),
                )
                .child(
                    div()
                        .id("usage-table")
                        .flex_1()
                        .w_full()
                        .min_h_0()
                        .overflow_y_scrollbar()
                        .child(render_usage_table(&rows, self.usage_tab, cx)),
                )
            })
    }

    fn render_settings(&self, settings: &Settings, cx: &mut Context<Self>) -> impl IntoElement {
        let save_error = self.settings.read(cx).error.clone();
        div().id("settings-pane").w_full().child(
            v_flex()
                .w_full()
                .gap_4()
                .when_some(save_error, |this, err| this.child(error_label(err, cx)))
                .child(self.render_general_settings(settings, cx))
                .child(self.render_menu_bar_settings(settings, cx))
                .child(self.render_refresh_settings(settings, cx)),
        )
    }

    fn render_general_settings(
        &self,
        settings: &Settings,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let login = self.login_item;
        let start_hidden = settings.start_hidden;
        section("General", cx)
            .child(setting_row(
                "Open at login",
                (!login.is_available()).then_some("Available in the installed app."),
                Switch::new("open-at-login")
                    .checked(login.is_enabled())
                    .disabled(!login.is_available())
                    .on_click(
                        cx.listener(|this, enabled: &bool, _, cx| {
                            this.set_login_item(*enabled, cx)
                        }),
                    ),
                cx,
            ))
            .when(login == LoginItemStatus::RequiresApproval, |this| {
                this.child(
                    h_flex()
                        .w_full()
                        .items_center()
                        .justify_between()
                        .gap_4()
                        .child(caption("macOS is waiting for approval.", cx))
                        .child(
                            Button::new("open-login-items")
                                .ghost()
                                .compact()
                                .label("Open Login Items")
                                .on_click(|_, _, _| login_item::open_login_items_settings()),
                        ),
                )
            })
            .when_some(self.login_error.clone(), |this, err| {
                this.child(error_label(err, cx))
            })
            .child(setting_row(
                "Start in the menu bar only",
                Some("Launch without opening the main window."),
                Switch::new("start-hidden")
                    .checked(start_hidden)
                    .on_click(cx.listener(|this, hidden: &bool, _, cx| {
                        let hidden = *hidden;
                        this.edit_settings(move |settings| settings.start_hidden = hidden, cx);
                    })),
                cx,
            ))
    }

    fn render_menu_bar_settings(
        &self,
        settings: &Settings,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let display = settings.menu_bar.clone();
        // Unticking the last one would leave the menu bar reading `Claude —`
        // with nothing but this pane to get a figure back.
        let last_one = display.shown_count() == 1;
        let windows = [
            (
                QuotaKind::FiveHour,
                "menu-bar-five-hour",
                display.show_five_hour,
            ),
            (
                QuotaKind::SevenDay,
                "menu-bar-seven-day",
                display.show_seven_day,
            ),
        ];
        let percent_index = PercentMode::ALL
            .iter()
            .position(|mode| *mode == display.percent);
        let preview = crate::status_title(self.store.read(cx), &display);
        let show_labels = display.show_labels;
        let show_reset = display.show_reset;

        section("Menu bar", cx)
            .child(setting_row(
                "Windows",
                Some("Choose which usage windows appear in the menu bar."),
                h_flex().gap_4().children(windows.map(|(kind, id, shown)| {
                    Checkbox::new(id)
                        .label(kind.label())
                        .checked(shown)
                        .disabled(shown && last_one)
                        .on_click(cx.listener(move |this, on: &bool, _, cx| {
                            this.toggle_menu_bar_window(kind, *on, cx)
                        }))
                })),
                cx,
            ))
            .child(setting_row(
                "Percentages",
                Some("Show how much is left or how much has been used."),
                RadioGroup::horizontal("percent-mode")
                    .flex_none()
                    .selected_index(percent_index)
                    .children(PercentMode::ALL.map(|mode| mode.label()))
                    .on_click(cx.listener(|this, index: &usize, _, cx| {
                        let Some(mode) = PercentMode::ALL.get(*index).copied() else {
                            return;
                        };
                        this.edit_settings(move |settings| settings.menu_bar.percent = mode, cx);
                    })),
                cx,
            ))
            .child(setting_row(
                "Show 5h and 7d labels",
                Some("Prefix each percentage with 5h or 7d."),
                Switch::new("menu-bar-labels")
                    .checked(show_labels)
                    .on_click(cx.listener(|this, on: &bool, _, cx| {
                        let on = *on;
                        this.edit_settings(move |settings| settings.menu_bar.show_labels = on, cx);
                    })),
                cx,
            ))
            .child(setting_row(
                "Show time until reset",
                Some("Add a reset countdown after each percentage."),
                Switch::new("menu-bar-reset")
                    .checked(show_reset)
                    .on_click(cx.listener(|this, on: &bool, _, cx| {
                        let on = *on;
                        this.edit_settings(move |settings| settings.menu_bar.show_reset = on, cx);
                    })),
                cx,
            ))
            .child(setting_row(
                "Preview",
                None,
                div()
                    .px_2()
                    .py_1()
                    .bg(cx.theme().muted)
                    .child(Label::new(preview).text_sm()),
                cx,
            ))
    }

    fn render_refresh_settings(
        &self,
        settings: &Settings,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let selected = RefreshRate::ALL
            .iter()
            .position(|rate| *rate == settings.refresh);
        section("Refresh", cx).child(setting_row(
            "In the menu bar",
            Some("Each refresh makes one usage API call. The open window refreshes every minute."),
            RadioGroup::horizontal("refresh-rate")
                .flex_none()
                .selected_index(selected)
                .children(RefreshRate::ALL.map(|rate| rate.label()))
                .on_click(cx.listener(|this, index: &usize, _, cx| {
                    let Some(rate) = RefreshRate::ALL.get(*index).copied() else {
                        return;
                    };
                    this.edit_settings(move |settings| settings.refresh = rate, cx);
                })),
            cx,
        ))
    }
}

/// A bordered block with a heading, matching the quota cards.
fn section(title: &'static str, cx: &App) -> Div {
    v_flex()
        .w_full()
        .gap_3()
        .p_4()
        .border_1()
        .border_color(cx.theme().border)
        .rounded(cx.theme().radius)
        .child(
            Label::new(title)
                .text_sm()
                .font_medium()
                .text_color(cx.theme().muted_foreground),
        )
}

fn setting_row(
    label: &'static str,
    description: Option<&'static str>,
    control: impl IntoElement,
    cx: &App,
) -> impl IntoElement {
    h_flex()
        .w_full()
        .items_start()
        .gap_4()
        .child(
            v_flex()
                .flex_1()
                .min_w_0()
                .gap_1()
                .child(Label::new(label).text_sm())
                .when_some(description, |this, description| {
                    this.child(caption(description, cx))
                }),
        )
        .child(div().flex_shrink_0().child(control))
}

fn caption(text: impl Into<SharedString>, cx: &App) -> impl IntoElement {
    div()
        .min_w_0()
        .text_xs()
        .text_color(cx.theme().muted_foreground)
        .child(text.into())
}

fn loading_state(cx: &App) -> impl IntoElement {
    v_flex().size_full().items_center().justify_center().child(
        Spinner::new()
            .large()
            .icon(IconName::LoaderCircle)
            .color(cx.theme().primary),
    )
}

fn logged_out_state(cx: &App) -> impl IntoElement {
    v_flex()
        .flex_1()
        .w_full()
        .items_center()
        .justify_center()
        .gap_1()
        .child(Label::new("Not logged in").text_color(cx.theme().muted_foreground))
        .child(caption(
            "Run `claude auth login` in Terminal. This picks it up on the next refresh.",
            cx,
        ))
}

/// Only reached with no OAuth token anywhere and no `claude` on the shell's
/// PATH or in any of the usual install directories. See `cli::locate`.
fn cli_not_installed_state(cx: &App) -> impl IntoElement {
    v_flex()
        .flex_1()
        .w_full()
        .items_center()
        .justify_center()
        .gap_3()
        .child(
            v_flex()
                .items_center()
                .gap_1()
                .child(Label::new("Claude Code not found").text_color(cx.theme().muted_foreground))
                .child(caption(
                    "Looked on your shell's PATH and in the usual install locations.",
                    cx,
                )),
        )
        .child(
            h_flex()
                .gap_2()
                .child(
                    Button::new("install-claude-code")
                        .primary()
                        .label("Install Claude Code")
                        .on_click(|_, _, cx| cx.open_url(CLAUDE_CODE_INSTALL_URL)),
                )
                .child(
                    Button::new("check-claude-code")
                        .label("Check again")
                        .on_click(|_, _, cx| {
                            UsageStore::global(cx).update(cx, |store, cx| store.reload(cx))
                        }),
                ),
        )
}

fn error_label(err: SharedString, cx: &App) -> impl IntoElement {
    Label::new(err).text_sm().text_color(cx.theme().danger)
}

/// Indices follow `TABS`.
fn tab_rows(report: &UsageReport, tab: usize) -> &[UsageRow] {
    match tab {
        1 => &report.weekly,
        2 => &report.monthly,
        3 => &report.sessions,
        4 => &report.blocks,
        _ => &report.daily,
    }
}

fn tab_columns(tab: usize) -> (&'static str, &'static str) {
    match tab {
        1 => ("Week", "Models"),
        2 => ("Month", "Models"),
        3 => ("Session", "Last active"),
        4 => ("Started", "Status"),
        _ => ("Day", "Models"),
    }
}

fn render_usage_table(rows: &[UsageRow], tab: usize, cx: &App) -> impl IntoElement {
    let (first, second) = tab_columns(tab);
    let basis = title_basis(tab);
    Table::new()
        .w_full()
        .border_0()
        .child(
            TableHeader::new().bg(cx.theme().background).child(
                TableRow::new()
                    .child(text_head(first).flex_basis(relative(basis)))
                    .child(text_head(second))
                    .child(token_head("Input"))
                    .child(token_head("Output"))
                    .child(token_head("Cache write"))
                    .child(token_head("Cache read"))
                    .child(token_head("Total")),
            ),
        )
        .child(TableBody::new().children(rows.iter().map(|row| usage_table_row(row, basis, cx))))
}

/// Share of the row the first column takes, against 1.0 for every other column.
/// A session title carries a project name and an id, which needs more room than
/// a date does.
fn title_basis(tab: usize) -> f32 {
    if tab == 3 { 2. } else { 1. }
}

fn usage_table_row(row: &UsageRow, basis: f32, cx: &App) -> TableRow {
    let total_color = if row.active {
        cx.theme().success
    } else {
        cx.theme().foreground
    };
    TableRow::new()
        .child(text_cell(row.title.clone()).flex_basis(relative(basis)))
        .child(text_cell(row.detail.clone()).text_color(cx.theme().muted_foreground))
        .child(token_cell(row.tokens.input))
        .child(token_cell(row.tokens.output))
        .child(token_cell(row.tokens.cache_create))
        .child(token_cell(row.tokens.cache_read))
        .child(token_cell(row.tokens.total()).text_color(total_color))
}

/// The table component's cells default to a 100px floor, which is wider than
/// seven columns can share. Zeroing it lets them shrink; clipping the text
/// keeps a long model list from painting over the next column.
fn clipped_cell() -> TableCell {
    TableCell::new()
        .min_w(px(0.))
        .overflow_hidden()
        .whitespace_nowrap()
}

fn clipped_head() -> TableHead {
    TableHead::new()
        .min_w(px(0.))
        .overflow_hidden()
        .whitespace_nowrap()
}

fn clipped_text(text: impl Into<SharedString>) -> Div {
    div()
        .w_full()
        .overflow_hidden()
        .text_ellipsis()
        .whitespace_nowrap()
        .child(text.into())
}

fn text_head(label: &'static str) -> TableHead {
    clipped_head().child(clipped_text(label))
}

fn token_head(label: &'static str) -> TableHead {
    clipped_head().text_right().child(clipped_text(label))
}

fn text_cell(text: impl Into<SharedString>) -> TableCell {
    clipped_cell().child(clipped_text(text))
}

fn token_cell(value: u64) -> TableCell {
    clipped_cell()
        .text_right()
        .child(clipped_text(format_tokens(value)))
}

/// All three windows, whatever the menu bar was told to carry: the settings
/// there are about what fits in a menu bar, and this has the room.
fn render_quota_limits(limits: &QuotaLimits, percent: PercentMode, cx: &App) -> impl IntoElement {
    h_flex()
        .w_full()
        .gap_3()
        .when_some(limits.five_hour.clone(), |this, window| {
            this.child(render_quota_window(
                QuotaKind::FiveHour,
                "quota-5h",
                &window,
                percent,
                cx,
            ))
        })
        .when_some(limits.seven_day.clone(), |this, window| {
            this.child(render_quota_window(
                QuotaKind::SevenDay,
                "quota-7d",
                &window,
                percent,
                cx,
            ))
        })
        .when_some(limits.seven_day_opus.clone(), |this, window| {
            this.child(render_quota_window(
                QuotaKind::Opus,
                "quota-opus",
                &window,
                percent,
                cx,
            ))
        })
}

fn render_quota_window(
    kind: QuotaKind,
    id: &'static str,
    window: &QuotaWindow,
    percent: PercentMode,
    cx: &App,
) -> impl IntoElement {
    // The colours track what is left however the label is worded: an amber bar
    // means the same thing whether it reads 20% left or 80% used.
    let remaining = window.remaining;
    let color = if remaining <= DANGER_REMAINING {
        cx.theme().danger
    } else if remaining <= WARNING_REMAINING {
        cx.theme().warning
    } else {
        cx.theme().success
    };
    v_flex()
        .flex_1()
        .gap_1()
        .p_3()
        .border_1()
        .border_color(cx.theme().border)
        .rounded(cx.theme().radius)
        .child(
            h_flex()
                .w_full()
                .justify_between()
                .items_center()
                .child(Label::new(kind.label()).text_sm())
                .child(Label::new(window.percent_label(percent)).text_sm()),
        )
        .child(
            // The bar fills with what is spent, whichever way the label counts.
            Progress::new(id)
                .value(window.used as f32)
                .small()
                .color(color),
        )
        .child(
            Label::new(window.timing_label(kind))
                .text_xs()
                .text_color(cx.theme().muted_foreground),
        )
}
