//! What the app has been told to prefer: which figures the menu bar carries,
//! whether a launch puts a window on screen, and how often the menu bar goes
//! back to the API. Kept as one JSON file in Application Support rather than in
//! user defaults, so it is something a person can read, diff, and delete.
//!
//! Every default reproduces what the app did before there were settings, so an
//! existing install sees no change until someone opens the pane.

use crate::APP_ID;
use gpui::prelude::*;
use gpui::{App, Context, Entity, Global, SharedString};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::time::Duration;

const SETTINGS_FILE: &str = "settings.json";
const NO_HOME: &str = "No home directory to save settings in";

/// Which way the percentages run. The choice applies to the menu bar, the
/// dropdown, and the window at once: `38% used` next to `62% left` reads like a
/// bug even though both are true.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PercentMode {
    /// `62% left`, counting down what is still available.
    #[default]
    Left,
    /// `38% used`, counting up what has been spent.
    Used,
}

impl PercentMode {
    pub const ALL: [Self; 2] = [Self::Left, Self::Used];

    pub fn label(self) -> &'static str {
        match self {
            Self::Left => "Left",
            Self::Used => "Used",
        }
    }
}

/// How often the limits are re-fetched while only the menu bar is showing. The
/// window keeps its own minute, since something on screen is being watched.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RefreshRate {
    OneMinute,
    /// What the app polled at before this was a setting.
    #[default]
    FiveMinutes,
    FifteenMinutes,
}

impl RefreshRate {
    pub const ALL: [Self; 3] = [Self::OneMinute, Self::FiveMinutes, Self::FifteenMinutes];

    pub fn interval(self) -> Duration {
        match self {
            Self::OneMinute => Duration::from_secs(60),
            Self::FiveMinutes => Duration::from_secs(300),
            Self::FifteenMinutes => Duration::from_secs(900),
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::OneMinute => "1 min",
            Self::FiveMinutes => "5 min",
            Self::FifteenMinutes => "15 min",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct MenuBarSettings {
    pub show_five_hour: bool,
    pub show_seven_day: bool,
    pub percent: PercentMode,
    /// `5h 62%` against a bare `62%`.
    pub show_labels: bool,
    /// Appends the countdown to the next reset: `5h 62% (2h41m)`.
    pub show_reset: bool,
}

impl Default for MenuBarSettings {
    fn default() -> Self {
        Self {
            show_five_hour: true,
            show_seven_day: true,
            percent: PercentMode::Left,
            show_labels: true,
            show_reset: false,
        }
    }
}

impl MenuBarSettings {
    /// How many windows are currently ticked. The pane uses it to refuse the
    /// last one: with nothing selected the menu bar reads `Claude —` for good.
    pub fn shown_count(&self) -> usize {
        [self.show_five_hour, self.show_seven_day]
            .into_iter()
            .filter(|shown| *shown)
            .count()
    }
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub menu_bar: MenuBarSettings,
    /// Launch straight into the menu bar with no window. The point of it is a
    /// login launch, which should not put a window in front of anyone.
    pub start_hidden: bool,
    pub refresh: RefreshRate,
}

impl Settings {
    fn path() -> Option<PathBuf> {
        std::env::var_os("HOME").map(|home| {
            PathBuf::from(home)
                .join("Library/Application Support")
                .join(APP_ID)
                .join(SETTINGS_FILE)
        })
    }

    /// Anything missing, unreadable, or malformed comes back as the defaults.
    /// There is nowhere to report a parse error to at this point, and a settings
    /// file is not worth failing to reach the menu bar over.
    pub fn load() -> Self {
        Self::path()
            .and_then(|path| std::fs::read_to_string(path).ok())
            .and_then(|text| serde_json::from_str(&text).ok())
            .unwrap_or_default()
    }

    pub fn save(&self) -> Result<(), String> {
        let path = Self::path().ok_or(NO_HOME)?;
        let dir = path.parent().ok_or(NO_HOME)?;
        std::fs::create_dir_all(dir)
            .map_err(|err| format!("Could not create {}: {err}", dir.display()))?;
        let json = serde_json::to_string_pretty(self)
            .map_err(|err| format!("Could not encode settings: {err}"))?;
        // Written alongside and renamed over, so a crash mid-write leaves the
        // old settings rather than half of the new ones.
        let temp = path.with_extension("json.tmp");
        std::fs::write(&temp, json)
            .map_err(|err| format!("Could not write {}: {err}", temp.display()))?;
        std::fs::rename(&temp, &path)
            .map_err(|err| format!("Could not save {}: {err}", path.display()))
    }
}

/// The settings, as an app global, so the menu bar and the window read the same
/// copy. Shaped like `UsageStore`: an entity everything else observes.
pub struct SettingsStore {
    settings: Settings,
    /// Set when the last write failed. The pane shows it; nothing else cares,
    /// since the change is already live in memory either way.
    pub error: Option<SharedString>,
}

struct GlobalSettings(Entity<SettingsStore>);

impl Global for GlobalSettings {}

impl SettingsStore {
    pub fn init(cx: &mut App) -> Entity<Self> {
        let store = cx.new(|_| Self {
            settings: Settings::load(),
            error: None,
        });
        cx.set_global(GlobalSettings(store.clone()));
        store
    }

    pub fn global(cx: &App) -> Entity<Self> {
        cx.global::<GlobalSettings>().0.clone()
    }

    /// A copy for the render and status bar paths, which only ever read and
    /// would otherwise have to hold a borrow across a `cx` they also mutate.
    pub fn get(cx: &App) -> Settings {
        Self::global(cx).read(cx).settings.clone()
    }

    pub fn settings(&self) -> &Settings {
        &self.settings
    }

    /// The one way in: change, persist, notify. Observers repaint the menu bar
    /// and the pane off the notify.
    pub fn edit(&mut self, change: impl FnOnce(&mut Settings), cx: &mut Context<Self>) {
        change(&mut self.settings);
        self.error = self.settings.save().err().map(Into::into);
        cx.notify();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_are_what_the_app_did_before_settings_existed() {
        let settings = Settings::default();
        assert!(settings.menu_bar.show_five_hour);
        assert!(settings.menu_bar.show_seven_day);
        assert!(settings.menu_bar.show_labels);
        assert!(!settings.menu_bar.show_reset);
        assert_eq!(settings.menu_bar.percent, PercentMode::Left);
        assert!(!settings.start_hidden);
        assert_eq!(settings.refresh.interval(), Duration::from_secs(300));
    }

    #[test]
    fn round_trips_through_json() {
        let settings = Settings {
            menu_bar: MenuBarSettings {
                show_five_hour: false,
                show_seven_day: true,
                percent: PercentMode::Used,
                show_labels: false,
                show_reset: true,
            },
            start_hidden: true,
            refresh: RefreshRate::FifteenMinutes,
        };
        let json = serde_json::to_string(&settings).unwrap();
        assert_eq!(serde_json::from_str::<Settings>(&json).unwrap(), settings);
    }

    /// A file written by an older build is missing whatever was added since, and
    /// one written by a newer build carries fields this one has never heard of.
    /// Neither may throw the rest of the settings away.
    #[test]
    fn a_partial_file_fills_the_rest_in_from_the_defaults() {
        let json = r#"{"start_hidden":true,"menu_bar":{"show_opus":true},"future":42}"#;
        let settings: Settings = serde_json::from_str(json).unwrap();
        assert!(settings.start_hidden);
        assert!(settings.menu_bar.show_five_hour);
        assert_eq!(settings.refresh, RefreshRate::FiveMinutes);
        assert!(
            !serde_json::to_string(&settings)
                .unwrap()
                .contains("show_opus")
        );
    }

    /// The file is one a person can open and edit, so the names in it are part
    /// of what this promises. Pinned rather than left to whatever serde does
    /// with a renamed variant.
    #[test]
    fn the_names_on_disk_are_the_ones_documented() {
        let json = r#"{
            "menu_bar": {
                "show_five_hour": true,
                "show_seven_day": true,
                "percent": "used",
                "show_labels": false,
                "show_reset": true
            },
            "start_hidden": false,
            "refresh": "one_minute"
        }"#;
        let settings: Settings = serde_json::from_str(json).unwrap();
        assert!(!settings.menu_bar.show_labels);
        assert!(settings.menu_bar.show_reset);
        assert_eq!(settings.menu_bar.percent, PercentMode::Used);
        assert_eq!(settings.refresh, RefreshRate::OneMinute);
        assert!(!settings.start_hidden);
    }

    #[test]
    fn the_last_ticked_window_is_countable() {
        let mut menu_bar = MenuBarSettings::default();
        assert_eq!(menu_bar.shown_count(), 2);
        menu_bar.show_seven_day = false;
        assert_eq!(menu_bar.shown_count(), 1);
    }
}
