//! The "Open at login" switch, backed by `SMAppService`. Registering the app
//! itself is a single call on macOS 13 and later, which is what the bundle
//! targets, so there is no helper tool and no launch agent to keep in step.
//!
//! Nothing here is written to `settings.json`. macOS owns this one: it can be
//! revoked from System Settings without the app running, and a copy of ours
//! would only be a second answer that is sometimes wrong.
#![allow(unexpected_cfgs)]

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LoginItemStatus {
    Enabled,
    NotRegistered,
    /// Registered, but macOS is holding it until someone confirms in System
    /// Settings, or it has been switched off there.
    RequiresApproval,
    /// Service Management could not find a registration record. A new app can
    /// report this before its first `register` call, so this status alone does
    /// not say whether the executable lives in an app bundle.
    NotFound,
}

impl LoginItemStatus {
    /// Whether the switch should read as on. Approval pending counts: the
    /// request has been made, and it is macOS that has not finished with it.
    pub fn is_enabled(self) -> bool {
        matches!(self, Self::Enabled | Self::RequiresApproval)
    }

    /// False under `cargo run`, where there is no app bundle to register. A
    /// bundled app remains available when macOS reports `NotFound`, since the
    /// first registration is what creates its Background Task Management row.
    pub fn is_available(self) -> bool {
        if !matches!(self, Self::NotFound) {
            return true;
        }
        is_bundled_app()
    }
}

#[cfg(target_os = "macos")]
fn is_bundled_app() -> bool {
    std::env::current_exe().is_ok_and(|executable| is_app_bundle_executable(&executable))
}

#[cfg(not(target_os = "macos"))]
fn is_bundled_app() -> bool {
    false
}

#[cfg(target_os = "macos")]
fn is_app_bundle_executable(executable: &std::path::Path) -> bool {
    let Some(macos) = executable.parent() else {
        return false;
    };
    let Some(contents) = macos.parent() else {
        return false;
    };
    let Some(bundle) = contents.parent() else {
        return false;
    };

    macos.file_name().is_some_and(|name| name == "MacOS")
        && contents.file_name().is_some_and(|name| name == "Contents")
        && bundle
            .extension()
            .is_some_and(|extension| extension == "app")
}

#[cfg(target_os = "macos")]
pub use platform::{open_login_items_settings, set_enabled, status};

#[cfg(target_os = "macos")]
mod platform {
    use super::LoginItemStatus;
    use cocoa::base::{id, nil};
    use objc::{class, msg_send, sel, sel_impl};
    use std::ffi::CStr;
    use std::os::raw::c_char;

    /// `SMAppServiceStatus`. Anything else is treated as nothing registered.
    const STATUS_NOT_REGISTERED: i64 = 0;
    const STATUS_ENABLED: i64 = 1;
    const STATUS_REQUIRES_APPROVAL: i64 = 2;
    const STATUS_NOT_FOUND: i64 = 3;

    const UNKNOWN_FAILURE: &str = "macOS refused the change without saying why";

    pub fn status() -> LoginItemStatus {
        unsafe {
            let service: id = msg_send![class!(SMAppService), mainAppService];
            if service == nil {
                return LoginItemStatus::NotFound;
            }
            let raw: i64 = msg_send![service, status];
            match raw {
                STATUS_NOT_REGISTERED => LoginItemStatus::NotRegistered,
                STATUS_ENABLED => LoginItemStatus::Enabled,
                STATUS_REQUIRES_APPROVAL => LoginItemStatus::RequiresApproval,
                STATUS_NOT_FOUND => LoginItemStatus::NotFound,
                _ => LoginItemStatus::NotFound,
            }
        }
    }

    pub fn set_enabled(enabled: bool) -> Result<(), String> {
        unsafe {
            let service: id = msg_send![class!(SMAppService), mainAppService];
            if service == nil {
                return Err(UNKNOWN_FAILURE.into());
            }
            let mut error: id = nil;
            let ok: bool = if enabled {
                msg_send![service, registerAndReturnError: &mut error]
            } else {
                msg_send![service, unregisterAndReturnError: &mut error]
            };
            if ok {
                return Ok(());
            }
            Err(error_message(error))
        }
    }

    /// System Settings, on the Login Items pane, for the case where macOS wants
    /// the registration confirmed by hand.
    pub fn open_login_items_settings() {
        unsafe {
            let _: () = msg_send![class!(SMAppService), openSystemSettingsLoginItems];
        }
    }

    unsafe fn error_message(error: id) -> String {
        unsafe {
            if error == nil {
                return UNKNOWN_FAILURE.into();
            }
            let description: id = msg_send![error, localizedDescription];
            if description == nil {
                return UNKNOWN_FAILURE.into();
            }
            let bytes: *const c_char = msg_send![description, UTF8String];
            if bytes.is_null() {
                return UNKNOWN_FAILURE.into();
            }
            CStr::from_ptr(bytes).to_string_lossy().into_owned()
        }
    }
}

#[cfg(not(target_os = "macos"))]
pub fn status() -> LoginItemStatus {
    LoginItemStatus::NotFound
}

#[cfg(not(target_os = "macos"))]
pub fn set_enabled(_enabled: bool) -> Result<(), String> {
    Err("Login items are a macOS feature".into())
}

#[cfg(not(target_os = "macos"))]
pub fn open_login_items_settings() {}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::is_app_bundle_executable;
    use std::path::Path;

    #[test]
    fn recognizes_an_app_bundle_executable() {
        assert!(is_app_bundle_executable(Path::new(
            "/Applications/Claude Code Usage.app/Contents/MacOS/claude-usage"
        )));
    }

    #[test]
    fn rejects_an_unbundled_executable() {
        assert!(!is_app_bundle_executable(Path::new(
            "/project/target/debug/claude-usage"
        )));
    }

    #[test]
    fn rejects_a_similarly_named_directory() {
        assert!(!is_app_bundle_executable(Path::new(
            "/tmp/Claude Code Usage.app/MacOS/claude-usage"
        )));
    }
}
