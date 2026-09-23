//! The handoff from the long-running Rust app to the WidgetKit extension.
//! WidgetKit renders in another process, so the extension reads a small JSON
//! snapshot from their shared App Group instead of touching GPUI or the token.

use crate::limits::QuotaKind;
use crate::settings::{MenuBarSettings, PercentMode};
use crate::store::UsageStore;
use serde::Serialize;
use std::cell::RefCell;
use std::fs;
use std::path::Path;

const SNAPSHOT_VERSION: u8 = 1;
const SNAPSHOT_FILE: &str = "widget-snapshot.json";

thread_local! {
    /// The last content WidgetKit was asked to render. The fetch timestamp is
    /// deliberately absent from this value, so a poll that returns identical
    /// limits updates the file without spending another widget reload request.
    static LAST_DISPLAY: RefCell<Option<Vec<u8>>> = const { RefCell::new(None) };
}

#[derive(Clone, Debug, PartialEq, Serialize)]
struct WidgetSnapshot {
    schema_version: u8,
    state: WidgetState,
    updated_at: Option<String>,
    percent_mode: PercentMode,
    windows: Vec<WidgetWindow>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
enum WidgetState {
    Loading,
    Ready,
    SignedOut,
    Unavailable,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
struct WidgetWindow {
    kind: WidgetWindowKind,
    used: f64,
    remaining: f64,
    resets_at: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
enum WidgetWindowKind {
    FiveHour,
    SevenDay,
}

impl WidgetSnapshot {
    fn from_store(store: &UsageStore, display: &MenuBarSettings) -> Self {
        if store.logged_in == Some(false) {
            return Self::without_windows(WidgetState::SignedOut, display.percent);
        }
        if store.limits_error.is_some() {
            return Self::without_windows(WidgetState::Unavailable, display.percent);
        }

        let Some(limits) = store.limits.as_ref() else {
            let state = if store.loading {
                WidgetState::Loading
            } else {
                WidgetState::Unavailable
            };
            return Self::without_windows(state, display.percent);
        };

        let windows = limits
            .shown(display)
            .into_iter()
            .filter_map(|(kind, window)| {
                let kind = match kind {
                    QuotaKind::FiveHour => WidgetWindowKind::FiveHour,
                    QuotaKind::SevenDay => WidgetWindowKind::SevenDay,
                    QuotaKind::Opus => return None,
                };
                Some(WidgetWindow {
                    kind,
                    used: window.used,
                    remaining: window.remaining,
                    resets_at: window.resets_at.map(|date| date.to_rfc3339()),
                })
            })
            .collect();

        Self {
            schema_version: SNAPSHOT_VERSION,
            state: WidgetState::Ready,
            updated_at: store.limits_updated_at.map(|date| date.to_rfc3339()),
            percent_mode: display.percent,
            windows,
        }
    }

    fn without_windows(state: WidgetState, percent_mode: PercentMode) -> Self {
        Self {
            schema_version: SNAPSHOT_VERSION,
            state,
            updated_at: None,
            percent_mode,
            windows: Vec::new(),
        }
    }

    /// The view does not display sub-second fetch metadata. Removing only the
    /// successful-fetch timestamp leaves every visible value in the signature.
    fn display_signature(&self) -> Result<Vec<u8>, serde_json::Error> {
        let mut display = self.clone();
        display.updated_at = None;
        serde_json::to_vec(&display)
    }
}

/// Writes the current snapshot when this build belongs to an App Group. Plain
/// `cargo run` and ad-hoc bundles have no group id and stop here.
pub fn sync(store: &UsageStore, display: &MenuBarSettings) {
    let Some(group_id) = option_env!("APP_GROUP_ID") else {
        return;
    };
    let Some(container) = crate::macos::app_group_container(group_id) else {
        return;
    };

    let snapshot = WidgetSnapshot::from_store(store, display);
    let Ok(contents) = serde_json::to_vec_pretty(&snapshot) else {
        return;
    };
    if write_if_changed(&container.join(SNAPSHOT_FILE), &contents).is_err() {
        return;
    }

    let Ok(signature) = snapshot.display_signature() else {
        return;
    };
    let display_changed = LAST_DISPLAY.with(|slot| {
        let mut previous = slot.borrow_mut();
        if previous.as_ref() == Some(&signature) {
            false
        } else {
            *previous = Some(signature);
            true
        }
    });
    if display_changed {
        reload_timelines();
    }
}

/// Replaces the snapshot atomically and avoids touching the file when the bytes
/// have not changed. The return value is useful to the file-level tests and to
/// callers that may want to account for writes later.
fn write_if_changed(path: &Path, contents: &[u8]) -> Result<bool, String> {
    if fs::read(path)
        .ok()
        .is_some_and(|existing| existing == contents)
    {
        return Ok(false);
    }
    let parent = path
        .parent()
        .ok_or_else(|| "Widget snapshot has no parent directory".to_string())?;
    fs::create_dir_all(parent)
        .map_err(|err| format!("Could not create {}: {err}", parent.display()))?;
    let temp = path.with_extension("json.tmp");
    fs::write(&temp, contents)
        .map_err(|err| format!("Could not write {}: {err}", temp.display()))?;
    fs::rename(&temp, path).map_err(|err| format!("Could not save {}: {err}", path.display()))?;
    Ok(true)
}

#[cfg(target_os = "macos")]
fn reload_timelines() {
    unsafe { claude_usage_reload_widgets() }
}

#[cfg(not(target_os = "macos"))]
fn reload_timelines() {}

#[cfg(target_os = "macos")]
unsafe extern "C" {
    fn claude_usage_reload_widgets();
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::limits::{QuotaLimits, QuotaWindow};
    use chrono::{TimeZone, Utc};
    use std::time::{SystemTime, UNIX_EPOCH};

    fn timestamp() -> chrono::DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 8, 27, 12, 0, 0)
            .single()
            .unwrap()
    }

    fn quota(used: f64, reset_hour: u32) -> QuotaWindow {
        QuotaWindow {
            used,
            remaining: 100.0 - used,
            resets_at: Utc.with_ymd_and_hms(2026, 8, 27, reset_hour, 0, 0).single(),
        }
    }

    fn ready_store() -> UsageStore {
        let mut store = UsageStore::default();
        store.logged_in = Some(true);
        store.limits_updated_at = Some(timestamp());
        store.limits = Some(QuotaLimits {
            five_hour: Some(quota(38.0, 14)),
            seven_day: Some(quota(59.0, 18)),
            seven_day_opus: Some(quota(12.0, 20)),
        });
        store
    }

    #[test]
    fn ready_snapshot_mirrors_menu_selection_and_order() {
        let snapshot = WidgetSnapshot::from_store(
            &ready_store(),
            &MenuBarSettings {
                show_five_hour: true,
                show_seven_day: false,
                percent: PercentMode::Used,
                ..Default::default()
            },
        );
        assert_eq!(snapshot.state, WidgetState::Ready);
        assert_eq!(snapshot.percent_mode, PercentMode::Used);
        assert_eq!(
            snapshot.updated_at.as_deref(),
            Some("2026-08-27T12:00:00+00:00")
        );
        assert_eq!(snapshot.windows.len(), 1);
        assert_eq!(snapshot.windows[0].kind, WidgetWindowKind::FiveHour);
        assert_eq!(snapshot.windows[0].used, 38.0);

        let snapshot = WidgetSnapshot::from_store(&ready_store(), &MenuBarSettings::default());
        assert_eq!(
            snapshot
                .windows
                .iter()
                .map(|window| window.kind)
                .collect::<Vec<_>>(),
            [WidgetWindowKind::FiveHour, WidgetWindowKind::SevenDay]
        );
    }

    #[test]
    fn ready_snapshot_matches_the_swift_fixture() {
        let snapshot = WidgetSnapshot::from_store(&ready_store(), &MenuBarSettings::default());
        let actual = serde_json::to_value(snapshot).unwrap();
        let fixture: serde_json::Value =
            serde_json::from_str(include_str!("../widget/Fixtures/ready.json")).unwrap();
        assert_eq!(actual, fixture);
    }

    #[test]
    fn opus_never_enters_the_widget_contract() {
        let mut store = ready_store();
        store.limits.as_mut().unwrap().five_hour = None;
        store.limits.as_mut().unwrap().seven_day = None;
        let snapshot = WidgetSnapshot::from_store(&store, &MenuBarSettings::default());
        assert!(snapshot.windows.is_empty());
    }

    #[test]
    fn ready_data_survives_an_in_progress_refresh() {
        let mut store = ready_store();
        store.loading = true;
        assert_eq!(
            WidgetSnapshot::from_store(&store, &MenuBarSettings::default()).state,
            WidgetState::Ready
        );
    }

    #[test]
    fn a_failed_refresh_replaces_previous_ready_data() {
        let mut store = ready_store();
        store.limits_error = Some("Usage API returned HTTP 500".into());
        let snapshot = WidgetSnapshot::from_store(&store, &MenuBarSettings::default());
        assert_eq!(snapshot.state, WidgetState::Unavailable);
        assert!(snapshot.windows.is_empty());
        assert!(snapshot.updated_at.is_none());
    }

    #[test]
    fn empty_store_states_are_explicit() {
        let display = MenuBarSettings::default();
        let mut store = UsageStore::default();
        store.loading = true;
        assert_eq!(
            WidgetSnapshot::from_store(&store, &display).state,
            WidgetState::Loading
        );
        store.loading = false;
        assert_eq!(
            WidgetSnapshot::from_store(&store, &display).state,
            WidgetState::Unavailable
        );
        store.logged_in = Some(false);
        assert_eq!(
            WidgetSnapshot::from_store(&store, &display).state,
            WidgetState::SignedOut
        );
    }

    #[test]
    fn fetch_time_does_not_force_a_display_reload() {
        let first = WidgetSnapshot::from_store(&ready_store(), &MenuBarSettings::default());
        let mut later_store = ready_store();
        later_store.limits_updated_at = Some(timestamp() + chrono::Duration::minutes(5));
        let later = WidgetSnapshot::from_store(&later_store, &MenuBarSettings::default());
        assert_ne!(
            serde_json::to_vec(&first).unwrap(),
            serde_json::to_vec(&later).unwrap()
        );
        assert_eq!(
            first.display_signature().unwrap(),
            later.display_signature().unwrap()
        );
    }

    #[test]
    fn snapshot_replacement_is_atomic_and_deduplicated() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("claude-usage-widget-{unique}"));
        let path = dir.join(SNAPSHOT_FILE);
        assert!(write_if_changed(&path, b"first").unwrap());
        assert!(!write_if_changed(&path, b"first").unwrap());
        assert!(write_if_changed(&path, b"second").unwrap());
        assert_eq!(fs::read(&path).unwrap(), b"second");
        fs::remove_dir_all(dir).unwrap();
    }
}
