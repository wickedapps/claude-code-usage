use futures::StreamExt;
use futures::channel::mpsc;
use gpui::*;
use gpui_component::*;
use std::time::Duration;

mod app;
mod assets;
mod auth;
mod limits;
mod login_item;
mod macos;
mod session;
mod settings;
mod status_bar;
mod store;
mod usage;

use app::AppView;
use assets::Assets;
use limits::{QuotaKind, QuotaLimits, QuotaWindow};
use settings::{MenuBarSettings, SettingsStore};
use status_bar::MenuAction;
use store::UsageStore;

const WINDOW_TITLE: &str = "Claude Code Usage";
/// Set from BUNDLE_ID by scripts/bundle.sh so a signed build reports the same id
/// as its bundle. A plain `cargo run` gets the placeholder, which is fine: on
/// macOS the identity that matters is CFBundleIdentifier in the bundle's plist.
const APP_ID: &str = match option_env!("APP_BUNDLE_ID") {
    Some(id) => id,
    None => "com.example.claude-usage",
};
const WINDOW_SIZE: (f32, f32) = (800., 640.);
const WINDOW_MIN_SIZE: (f32, f32) = (560., 360.);
/// Shown in the menu bar before the first fetch lands.
const STATUS_LOADING: &str = "Claude…";
/// Shown when there is no figure to report, either because the fetch failed or
/// because nothing has been loaded yet.
const STATUS_UNKNOWN: &str = "Claude —";
const STATUS_SIGNED_OUT: &str = "Claude: signed out";
const STATUS_SEPARATOR: &str = " · ";
/// How often the menu bar title is rewritten so a reset countdown stays true.
/// The poll can be a quarter of an hour apart, which would leave `2h41m` on
/// screen long after it stopped meaning anything.
const COUNTDOWN_TICK: Duration = Duration::from_secs(30);

actions!(claude_usage, [Quit, Hide, HideOthers, ShowAll]);

/// Buttons, progress bars, and the quota cards all follow the theme radius.
/// Zeroing it squares the whole UI instead of leaving a mix of radii.
fn square_theme(cx: &mut App) {
    Theme::global_mut(cx).radius = px(0.);
    Theme::global_mut(cx).radius_lg = px(0.);
    Theme::sync_base(cx);
}

fn main() {
    // Has to happen before AppKit spins up.
    macos::prepare();

    let app = gpui_platform::application().with_assets(Assets);

    app.run(move |cx| {
        macos::become_accessory();
        // Unbundled runs have no plist to read an icon from, and the Dock tile
        // and Cmd-Tab entry appear as soon as the window does.
        macos::set_app_icon(assets::DOCK_ICON);
        gpui_component::init(cx);
        square_theme(cx);
        init_app_menu(cx);
        // The status item is the app's only permanent UI, so closing the window
        // must not take the process with it.
        cx.set_quit_mode(QuitMode::Explicit);

        // First of the three, because the other two read it: the poll rate comes
        // out of it, and so does whether a window goes up at all.
        let settings = SettingsStore::init(cx);
        let start_hidden = settings.read(cx).settings().start_hidden;

        let store = UsageStore::init(!start_hidden, cx);
        init_status_bar(&store, &settings, cx);
        // A launch nobody asked for, at login, should not put a window in front
        // of whatever they were doing. The status item is already up either way.
        if !start_hidden {
            open_main_window(cx);
        }
    });
}

/// The one window, kept across hides so Open has something to bring back. The
/// view is held alongside its handle because the status item's Settings… has to
/// reach past the window and switch the pane.
struct MainWindow {
    handle: WindowHandle<Root>,
    view: Entity<AppView>,
}

impl Global for MainWindow {}

/// Brings the window back, opening it the first time. It is only ever built
/// once: closing parks it off screen rather than destroying it, because GPUI
/// leaks a window's drawables on teardown and a second one would cost another
/// 28MB. See `macos::park_window`.
fn open_main_window(cx: &mut App) {
    // Regular for as long as the window is up, so the app has a Dock tile and an
    // app switcher entry while it is on screen. Parking puts it back.
    macos::set_dock_visible(true);

    if let Some(handle) = cx.try_global::<MainWindow>().map(|main| main.handle) {
        macos::unpark_window(WINDOW_TITLE);
        let shown = handle.update(cx, |_, window, _| {
            // The parked window skipped every frame it was asked for, so the
            // one it still holds was drawn against the old data.
            window.refresh();
            window.activate_window();
        });
        if shown.is_ok() {
            UsageStore::global(cx).update(cx, |store, cx| {
                store.set_window_open(true);
                store.reload(cx);
            });
            cx.activate(true);
            return;
        }
    }

    let bounds = Bounds::centered(None, size(px(WINDOW_SIZE.0), px(WINDOW_SIZE.1)), cx);
    // The root the window is built with is a `Root`, which gives nothing typed
    // back, so the view is caught on the way past.
    let mut built = None;
    let handle = cx
        .open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(bounds)),
                titlebar: Some(TitlebarOptions {
                    title: Some(WINDOW_TITLE.into()),
                    ..Default::default()
                }),
                app_id: Some(APP_ID.into()),
                window_min_size: Some(size(px(WINDOW_MIN_SIZE.0), px(WINDOW_MIN_SIZE.1))),
                ..Default::default()
            },
            |window, cx| {
                let view = cx.new(|cx| AppView::new(window, cx));
                built = Some(view.clone());
                cx.new(|cx| Root::new(view, window, cx))
            },
        )
        .expect("Failed to open window");
    handle
        .update(cx, |_, window, cx| {
            window.on_window_should_close(cx, |_, cx| {
                park_main_window(cx);
                false
            });
        })
        .ok();
    cx.set_global(MainWindow {
        handle,
        view: built.expect("window was built without a view"),
    });
    UsageStore::global(cx).update(cx, |store, _| store.set_window_open(true));
    // An accessory app is never the frontmost one by default, so say so.
    cx.activate(true);
}

/// The window, on the settings pane. What the status item's Settings… does, and
/// the only reason the view is kept next to the handle.
fn open_settings(cx: &mut App) {
    open_main_window(cx);
    let Some(view) = cx.try_global::<MainWindow>().map(|main| main.view.clone()) else {
        return;
    };
    view.update(cx, |view, cx| view.show_settings(cx));
}

/// What the close button does. The app carries on in the menu bar, and with no
/// window on screen it gives the Dock tile back and drops out of the app
/// switcher, leaving the status item as its only trace.
fn park_main_window(cx: &mut App) {
    macos::park_window(WINDOW_TITLE);
    macos::set_dock_visible(false);
    UsageStore::global(cx).update(cx, |store, _| store.set_window_open(false));
}

/// Puts the item in the menu bar and keeps its title in step with the store and
/// with the settings.
fn init_status_bar(store: &Entity<UsageStore>, settings: &Entity<SettingsStore>, cx: &mut App) {
    let (tx, mut rx) = mpsc::unbounded();
    status_bar::install(move |action| {
        // This fires from AppKit's menu tracking, outside any GPUI update, so
        // the action goes to a task that can borrow the app properly.
        tx.unbounded_send(action).ok();
    });

    sync_status_bar(cx);
    cx.observe(store, |_, cx| sync_status_bar(cx)).detach();
    // A switch flipped in the pane has to reach the menu bar there and then,
    // rather than at whatever remains of the poll interval.
    cx.observe(settings, |_, cx| sync_status_bar(cx)).detach();
    init_countdown_ticker(cx);

    cx.spawn(async move |cx| {
        while let Some(action) = rx.next().await {
            cx.update(|cx| match action {
                MenuAction::Refresh => {
                    UsageStore::global(cx).update(cx, |store, cx| store.reload(cx))
                }
                MenuAction::Open => open_main_window(cx),
                MenuAction::Settings => open_settings(cx),
                MenuAction::Quit => cx.quit(),
            });
        }
    })
    .detach();
}

/// Rewrites the title on its own clock, for the countdowns. Nothing is fetched
/// and the store is not notified, so with the countdown off this is a settings
/// read every thirty seconds and nothing else.
fn init_countdown_ticker(cx: &mut App) {
    cx.spawn(async move |cx| {
        loop {
            cx.background_executor().timer(COUNTDOWN_TICK).await;
            cx.update(|cx| {
                if SettingsStore::get(cx).menu_bar.show_reset {
                    sync_status_bar(cx);
                }
            });
        }
    })
    .detach();
}

fn sync_status_bar(cx: &App) {
    let store = UsageStore::global(cx);
    let store = store.read(cx);
    let display = SettingsStore::get(cx).menu_bar;
    status_bar::set_title(&status_title(store, &display));
    status_bar::set_menu_bar(menu_limits(store), display);
}

/// The windows shown in the dropdown. Signed out drops them so the menu does
/// not keep quoting a number the API is no longer standing behind.
fn menu_limits(store: &UsageStore) -> Option<QuotaLimits> {
    if store.logged_in == Some(false) {
        None
    } else {
        store.limits.clone()
    }
}

/// The menu bar line, e.g. `5h 62% · 7d 41%`. Which windows appear, which way
/// the figures run, and whether the labels and countdowns come with them are all
/// the settings' to say; the fallbacks below are not.
fn status_title(store: &UsageStore, display: &MenuBarSettings) -> String {
    if store.logged_in == Some(false) {
        return STATUS_SIGNED_OUT.into();
    }

    let Some(limits) = store.limits.as_ref() else {
        return if store.loading {
            STATUS_LOADING.into()
        } else {
            STATUS_UNKNOWN.into()
        };
    };

    let parts: Vec<String> = limits
        .shown(display)
        .into_iter()
        .map(|(kind, window)| status_part(kind, window, display))
        .collect();

    if parts.is_empty() {
        STATUS_UNKNOWN.into()
    } else {
        parts.join(STATUS_SEPARATOR)
    }
}

/// One window's worth of the line: `5h 62% (2h41m)`, with the label and the
/// countdown only there if they were asked for.
fn status_part(kind: QuotaKind, window: &QuotaWindow, display: &MenuBarSettings) -> String {
    let mut part = String::new();
    if display.show_labels {
        part.push_str(kind.short_label());
        part.push(' ');
    }
    part.push_str(&format!("{:.0}%", window.percent(display.percent)));
    if display.show_reset
        && let Some(countdown) = window.countdown_label()
    {
        part.push_str(&format!(" ({countdown})"));
    }
    part
}

/// This is the menu bar the app shows while its window is up, and the key
/// bindings GPUI routes to it. The actions also back the status item's Quit,
/// which fires while the app is an accessory and has no menu bar of its own.
fn init_app_menu(cx: &mut App) {
    cx.on_action(|_: &Quit, cx| cx.quit());
    cx.on_action(|_: &Hide, cx| cx.hide());
    cx.on_action(|_: &HideOthers, cx| cx.hide_other_apps());
    cx.on_action(|_: &ShowAll, cx| cx.unhide_other_apps());
    cx.bind_keys([
        KeyBinding::new("cmd-q", Quit, None),
        KeyBinding::new("cmd-h", Hide, None),
        KeyBinding::new("alt-cmd-h", HideOthers, None),
    ]);
    cx.set_menus([Menu::new(WINDOW_TITLE).items([
        MenuItem::os_submenu("Services", SystemMenuType::Services),
        MenuItem::separator(),
        MenuItem::action(format!("Hide {WINDOW_TITLE}"), Hide),
        MenuItem::action("Hide Others", HideOthers),
        MenuItem::action("Show All", ShowAll),
        MenuItem::separator(),
        MenuItem::action(format!("Quit {WINDOW_TITLE}"), Quit),
    ])]);
}

#[cfg(test)]
mod tests {
    // Named rather than globbed: `use gpui::*` at the crate root brings in
    // gpui's own `test` attribute, which shadows the built-in one and sends
    // `#[test]` into an expansion loop.
    use super::{
        MenuBarSettings, QuotaLimits, QuotaWindow, STATUS_LOADING, STATUS_SIGNED_OUT,
        STATUS_UNKNOWN, UsageStore, status_title,
    };
    use crate::settings::PercentMode;
    use chrono::Utc;

    fn window(remaining: f64, minutes_to_reset: Option<i64>) -> QuotaWindow {
        QuotaWindow {
            used: 100.0 - remaining,
            remaining,
            // Half a minute past, so the truncation to whole minutes cannot land
            // on the wrong side of the boundary while the test is running.
            resets_at: minutes_to_reset
                .map(|minutes| Utc::now() + chrono::Duration::seconds(minutes * 60 + 30)),
        }
    }

    fn limits() -> QuotaLimits {
        QuotaLimits {
            five_hour: Some(window(62.0, Some(161))),
            seven_day: Some(window(41.0, Some(3 * 24 * 60 + 4 * 60))),
            seven_day_opus: Some(window(88.0, None)),
        }
    }

    /// `window_open` is the store's own business, so the fields that matter
    /// here are set on a default rather than through struct update syntax.
    fn store_with(change: impl FnOnce(&mut UsageStore)) -> UsageStore {
        let mut store = UsageStore::default();
        change(&mut store);
        store
    }

    fn store() -> UsageStore {
        store_with(|store| {
            store.logged_in = Some(true);
            store.limits = Some(limits());
        })
    }

    #[test]
    fn the_defaults_still_read_the_way_they_did() {
        let display = MenuBarSettings::default();
        assert_eq!(status_title(&store(), &display), "5h 62% · 7d 41%");
    }

    #[test]
    fn labels_can_come_off() {
        let display = MenuBarSettings {
            show_labels: false,
            ..Default::default()
        };
        assert_eq!(status_title(&store(), &display), "62% · 41%");
    }

    #[test]
    fn the_figures_can_run_the_other_way() {
        let display = MenuBarSettings {
            percent: PercentMode::Used,
            ..Default::default()
        };
        assert_eq!(status_title(&store(), &display), "5h 38% · 7d 59%");
    }

    #[test]
    fn a_countdown_follows_each_figure_when_asked_for() {
        let display = MenuBarSettings {
            show_reset: true,
            ..Default::default()
        };
        assert_eq!(
            status_title(&store(), &display),
            "5h 62% (2h41m) · 7d 41% (3d4h)"
        );
    }

    /// The API does not always say when a window turns over, and a missing reset
    /// time should cost that window its countdown, not its place in the line.
    #[test]
    fn a_window_with_no_reset_time_keeps_its_figure() {
        let display = MenuBarSettings {
            show_reset: true,
            ..Default::default()
        };
        let mut store = store();
        store.limits.as_mut().unwrap().five_hour = Some(window(100.0, None));
        assert_eq!(status_title(&store, &display), "5h 100% · 7d 41% (3d4h)");
    }

    #[test]
    fn only_the_windows_asked_for_appear() {
        let display = MenuBarSettings {
            show_five_hour: false,
            show_seven_day: true,
            ..Default::default()
        };
        assert_eq!(status_title(&store(), &display), "7d 41%");
    }

    /// The pane refuses to untick the last window, but a hand-edited settings
    /// file can still ask for none of them.
    #[test]
    fn asking_for_no_windows_falls_back_to_the_placeholder() {
        let display = MenuBarSettings {
            show_five_hour: false,
            show_seven_day: false,
            ..Default::default()
        };
        assert_eq!(status_title(&store(), &display), STATUS_UNKNOWN);
    }

    /// A window the API did not report is not one the settings can conjure up.
    #[test]
    fn a_window_the_api_left_out_is_skipped() {
        let store = store_with(|store| {
            store.logged_in = Some(true);
            store.limits = Some(QuotaLimits {
                seven_day: Some(window(41.0, None)),
                ..Default::default()
            });
        });
        assert_eq!(status_title(&store, &MenuBarSettings::default()), "7d 41%");
    }

    #[test]
    fn the_fallbacks_ignore_the_settings() {
        let display = MenuBarSettings::default();
        let signed_out = store_with(|store| {
            store.logged_in = Some(false);
            store.limits = Some(limits());
        });
        assert_eq!(status_title(&signed_out, &display), STATUS_SIGNED_OUT);

        let first_load = store_with(|store| store.loading = true);
        assert_eq!(status_title(&first_load, &display), STATUS_LOADING);

        let failed = UsageStore::default();
        assert_eq!(status_title(&failed, &display), STATUS_UNKNOWN);
    }
}
