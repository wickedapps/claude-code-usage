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
    /// There is no registration to speak of, which is what an unbundled build
    /// always reports: `SMAppService` has no bundle to point launchd at.
    NotFound,
}

impl LoginItemStatus {
    /// Whether the switch should read as on. Approval pending counts: the
    /// request has been made, and it is macOS that has not finished with it.
    pub fn is_enabled(self) -> bool {
        matches!(self, Self::Enabled | Self::RequiresApproval)
    }

    /// False under `cargo run`, where there is no bundle to register and the
    /// switch would fail every time it was touched.
    pub fn is_available(self) -> bool {
        !matches!(self, Self::NotFound)
    }
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
