use crate::limits::{QuotaLimits, QuotaWindow};
use crate::store::UsageStore;
use crate::usage::{UsageReport, UsageRow, format_tokens};
use gpui::prelude::*;
use gpui::*;
use gpui_component::button::{Button, ButtonVariants};
use gpui_component::label::Label;
use gpui_component::progress::Progress;
use gpui_component::scroll::ScrollableElement;
use gpui_component::spinner::Spinner;
use gpui_component::tab::{Tab, TabBar};
use gpui_component::table::{Table, TableBody, TableCell, TableHead, TableHeader, TableRow};
use gpui_component::*;

/// Remaining percentage at or below which a quota bar turns red, then amber.
const DANGER_REMAINING: f64 = 10.0;
const WARNING_REMAINING: f64 = 30.0;

/// Tab labels, in the order the TabBar renders them. `tab_rows` maps the
/// selected index back onto the matching field of the report.
const TABS: [&str; 5] = ["Daily", "Weekly", "Monthly", "Session", "5h Block"];

pub struct AppView {
    store: Entity<UsageStore>,
    usage_tab: usize,
    /// Redraws the window whenever the store lands new numbers, including from
    /// a menu bar poll that nobody asked for here.
    _store_observer: Subscription,
}

impl AppView {
    pub fn new(_window: &mut Window, cx: &mut Context<Self>) -> Self {
        let store = UsageStore::global(cx);
        let observer = cx.observe(&store, |_, store, cx| {
            // Nothing to redraw for while the window is parked, and asking for a
            // frame it will never show costs a CoreAnimation commit and an
            // AppKit display cycle each time. Reopening reloads anyway.
            if !store.read(cx).window_open() {
                return;
            }
            cx.notify();
        });
        Self {
            store,
            usage_tab: 0,
            _store_observer: observer,
        }
    }

    fn reload(&mut self, cx: &mut Context<Self>) {
        self.store.update(cx, |store, cx| store.reload(cx));
    }

    fn show_usage_tab(&mut self, tab: usize, cx: &mut Context<Self>) {
        self.usage_tab = tab;
        cx.notify();
    }
}

/// Everything a render needs out of the store, copied out up front so the
/// borrow is over before the listeners below take `cx` mutably.
struct ViewState {
    loading: bool,
    initial_load: bool,
    logged_out: bool,
    has_dashboard: bool,
    has_usage: bool,
    auth_error: Option<SharedString>,
    usage_error: Option<SharedString>,
    limits_error: Option<SharedString>,
    limits: Option<QuotaLimits>,
}

impl From<&UsageStore> for ViewState {
    fn from(store: &UsageStore) -> Self {
        Self {
            loading: store.loading,
            initial_load: store.is_initial_load(),
            logged_out: !store.loading
                && store.logged_in == Some(false)
                && store.auth_error.is_none(),
            has_dashboard: store.has_dashboard(),
            has_usage: store.usage.is_some(),
            auth_error: store.auth_error.clone(),
            usage_error: store.usage_error.clone(),
            limits_error: store.limits_error.clone(),
            limits: store.limits.clone(),
        }
    }
}

impl Render for AppView {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let state = ViewState::from(self.store.read(cx));
        v_flex()
            .size_full()
            .p_6()
            .gap_4()
            .bg(cx.theme().background)
            .when(state.initial_load, |this| this.child(loading_state(cx)))
            .when(!state.initial_load, |this| {
                this.child(self.render_header(state.loading, cx))
            })
            .when_some(state.auth_error.clone(), |this, err| {
                this.child(error_label(err, cx))
            })
            .when(state.logged_out, |this| this.child(logged_out_state(cx)))
            .when(state.has_dashboard, |this| {
                this.child(self.render_dashboard(&state, cx))
            })
    }
}

impl AppView {
    fn render_header(&self, loading: bool, cx: &mut Context<Self>) -> impl IntoElement {
        h_flex()
            .w_full()
            .items_center()
            .justify_between()
            .child(Label::new("Claude Code Usage"))
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
    }

    fn render_dashboard(&self, state: &ViewState, cx: &mut Context<Self>) -> impl IntoElement {
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
                this.child(render_quota_limits(&limits, cx))
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
        .child(Label::new("Not logged in").text_color(cx.theme().muted_foreground))
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
        3 => ("Session", "Last"),
        4 => ("Started", "Status"),
        _ => ("Day", "Models"),
    }
}

fn render_usage_table(rows: &[UsageRow], tab: usize, cx: &App) -> impl IntoElement {
    let (first, second) = tab_columns(tab);
    Table::new()
        .w_full()
        .border_0()
        .child(
            TableHeader::new().bg(cx.theme().background).child(
                TableRow::new()
                    .child(text_head(first))
                    .child(text_head(second))
                    .child(token_head("Input"))
                    .child(token_head("Output"))
                    .child(token_head("Cache write"))
                    .child(token_head("Cache read"))
                    .child(token_head("Total")),
            ),
        )
        .child(TableBody::new().children(rows.iter().map(|row| usage_table_row(row, cx))))
}

fn usage_table_row(row: &UsageRow, cx: &App) -> TableRow {
    let total_color = if row.active {
        cx.theme().success
    } else {
        cx.theme().foreground
    };
    TableRow::new()
        .child(text_cell(row.title.clone()))
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

fn render_quota_limits(limits: &QuotaLimits, cx: &App) -> impl IntoElement {
    h_flex()
        .w_full()
        .gap_3()
        .when_some(limits.five_hour.clone(), |this, window| {
            this.child(render_quota_window("5-hour", "quota-5h", &window, cx))
        })
        .when_some(limits.seven_day.clone(), |this, window| {
            this.child(render_quota_window("Weekly", "quota-7d", &window, cx))
        })
        .when_some(limits.seven_day_opus.clone(), |this, window| {
            this.child(render_quota_window(
                "Opus weekly",
                "quota-opus",
                &window,
                cx,
            ))
        })
}

fn render_quota_window(
    title: &'static str,
    id: &'static str,
    window: &QuotaWindow,
    cx: &App,
) -> impl IntoElement {
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
                .child(Label::new(title).text_sm())
                .child(Label::new(format!("{:.0}% left", remaining)).text_sm()),
        )
        .child(
            // The bar fills with what is spent, while the label counts down.
            Progress::new(id)
                .value(window.used as f32)
                .small()
                .color(color),
        )
        .child(
            Label::new(window.resets_label())
                .text_xs()
                .text_color(cx.theme().muted_foreground),
        )
}
