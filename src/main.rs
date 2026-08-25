use futures::StreamExt;
use futures::channel::mpsc;
use gpui::*;
use gpui_component::*;

mod app;
mod assets;
mod auth;
mod limits;
mod macos;
mod session;
mod status_bar;
mod store;
mod usage;

use app::AppView;
use assets::Assets;
use limits::QuotaLimits;
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

        let store = UsageStore::init(cx);
        init_status_bar(&store, cx);
        open_main_window(cx);
    });
}

/// The one window, kept across hides so Open has something to bring back.
struct MainWindow(WindowHandle<Root>);

impl Global for MainWindow {}

/// Brings the window back, opening it the first time. It is only ever built
/// once: closing parks it off screen rather than destroying it, because GPUI
/// leaks a window's drawables on teardown and a second one would cost another
/// 28MB. See `macos::park_window`.
fn open_main_window(cx: &mut App) {
    // Regular for as long as the window is up, so the app has a Dock tile and an
    // app switcher entry while it is on screen. Parking puts it back.
    macos::set_dock_visible(true);

    if let Some(handle) = cx.try_global::<MainWindow>().map(|global| global.0) {
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
    cx.set_global(MainWindow(handle));
    UsageStore::global(cx).update(cx, |store, _| store.set_window_open(true));
    // An accessory app is never the frontmost one by default, so say so.
    cx.activate(true);
}

/// What the close button does. The app carries on in the menu bar, and with no
/// window on screen it gives the Dock tile back and drops out of the app
/// switcher, leaving the status item as its only trace.
fn park_main_window(cx: &mut App) {
    macos::park_window(WINDOW_TITLE);
    macos::set_dock_visible(false);
    UsageStore::global(cx).update(cx, |store, _| store.set_window_open(false));
}

/// Puts the item in the menu bar and keeps its title in step with the store.
fn init_status_bar(store: &Entity<UsageStore>, cx: &mut App) {
    let (tx, mut rx) = mpsc::unbounded();
    status_bar::install(move |action| {
        // This fires from AppKit's menu tracking, outside any GPUI update, so
        // the action goes to a task that can borrow the app properly.
        tx.unbounded_send(action).ok();
    });

    sync_status_bar(store.read(cx));
    cx.observe(store, |store, cx| {
        sync_status_bar(store.read(cx));
    })
    .detach();

    cx.spawn(async move |cx| {
        while let Some(action) = rx.next().await {
            cx.update(|cx| match action {
                MenuAction::Refresh => {
                    UsageStore::global(cx).update(cx, |store, cx| store.reload(cx))
                }
                MenuAction::Open => open_main_window(cx),
                MenuAction::Quit => cx.quit(),
            });
        }
    })
    .detach();
}

fn sync_status_bar(store: &UsageStore) {
    status_bar::set_title(&status_title(store));
    status_bar::set_limits(menu_limits(store));
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

/// The menu bar line, e.g. `5h 62% · 7d 41%`. Both figures are what is left, to
/// match the window.
fn status_title(store: &UsageStore) -> String {
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

    // Opus has its own weekly window, but three figures is more than the menu
    // bar can carry. It stays in the window.
    let parts: Vec<String> = [("5h", &limits.five_hour), ("7d", &limits.seven_day)]
        .into_iter()
        .filter_map(|(label, window)| {
            window
                .as_ref()
                .map(|window| format!("{label} {:.0}%", window.remaining))
        })
        .collect();

    if parts.is_empty() {
        STATUS_UNKNOWN.into()
    } else {
        parts.join(STATUS_SEPARATOR)
    }
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
