#![allow(unexpected_cfgs)]

#[cfg(target_os = "macos")]
use cocoa::appkit::{NSApp, NSApplication, NSApplicationActivationPolicy};
#[cfg(target_os = "macos")]
use cocoa::base::{NO, id, nil};
#[cfg(target_os = "macos")]
use cocoa::foundation::{NSRect, NSSize, NSString};
#[cfg(target_os = "macos")]
use objc::{class, msg_send, sel, sel_impl};
#[cfg(target_os = "macos")]
use std::ffi::{CStr, c_void};

/// Size the window's drawables shrink to while it is off screen. A CAMetalLayer
/// reallocates its buffers whenever this changes, so setting it small is what
/// actually returns the memory.
#[cfg(target_os = "macos")]
const PARKED_DRAWABLE: NSSize = NSSize {
    width: 1.0,
    height: 1.0,
};

/// Must run before the app starts. AppKit's autofill heuristics inspect every
/// window on launch and log warnings about GPUI's non-native view tree, so this
/// turns them off in the app's own user defaults.
#[cfg(target_os = "macos")]
pub fn prepare() {
    unsafe {
        let defaults: id = msg_send![class!(NSUserDefaults), standardUserDefaults];
        let key = NSString::alloc(nil).init_str("NSAutoFillHeuristicControllerEnabled");
        let value: id = msg_send![class!(NSNumber), numberWithBool: NO];
        let _: () = msg_send![defaults, setObject: value forKey: key];
    }
}

#[cfg(not(target_os = "macos"))]
pub fn prepare() {}

/// Drops the Dock tile and the app's own menu bar, leaving the status item as
/// the only permanent trace of the app. GPUI hardcodes the regular policy in
/// `applicationDidFinishLaunching:` and then hands control here, so this has to
/// run from inside `App::run` to be the one that sticks. The bundle also sets
/// `LSUIElement`, which spares a signed build the Dock icon flashing on launch.
#[cfg(target_os = "macos")]
pub fn become_accessory() {
    unsafe {
        NSApp().setActivationPolicy_(
            NSApplicationActivationPolicy::NSApplicationActivationPolicyAccessory,
        );
    }
}

#[cfg(not(target_os = "macos"))]
pub fn become_accessory() {}

/// The Dock tile and the Cmd-Tab entry belong to a regular app, and an accessory
/// has neither, so the policy follows the window: regular while it is on screen,
/// accessory once it is parked. Switching away from accessory leaves the app
/// behind the frontmost one until something activates it, which is why every
/// caller that shows the window activates afterwards.
#[cfg(target_os = "macos")]
pub fn set_dock_visible(visible: bool) {
    unsafe {
        NSApp().setActivationPolicy_(if visible {
            NSApplicationActivationPolicy::NSApplicationActivationPolicyRegular
        } else {
            NSApplicationActivationPolicy::NSApplicationActivationPolicyAccessory
        });
    }
}

#[cfg(not(target_os = "macos"))]
pub fn set_dock_visible(_visible: bool) {}

/// Points the Dock tile and the app switcher at the app's own artwork. A bundle
/// gets this from `CFBundleIconFile`, but a plain `cargo run` has no plist and
/// would otherwise show the generic executable icon.
#[cfg(target_os = "macos")]
pub fn set_app_icon(png: &[u8]) {
    unsafe {
        let data: id = msg_send![
            class!(NSData),
            dataWithBytes: png.as_ptr() as *const c_void
            length: png.len() as u64
        ];
        let image: id = msg_send![class!(NSImage), alloc];
        let image: id = msg_send![image, initWithData: data];
        if image == nil {
            return;
        }
        let _: () = msg_send![NSApp(), setApplicationIconImage: image];
        let _: () = msg_send![image, release];
    }
}

#[cfg(not(target_os = "macos"))]
pub fn set_app_icon(_png: &[u8]) {}

/// Resolves the shared container through Foundation rather than guessing its
/// path under `~/Library/Group Containers`. macOS returns `nil` when this build
/// has no matching App Group entitlement, which is the normal `cargo run` and
/// ad-hoc bundle behavior.
#[cfg(target_os = "macos")]
pub fn app_group_container(group_id: &str) -> Option<std::path::PathBuf> {
    unsafe {
        let manager: id = msg_send![class!(NSFileManager), defaultManager];
        let group = NSString::alloc(nil).init_str(group_id);
        let url: id = msg_send![
            manager,
            containerURLForSecurityApplicationGroupIdentifier: group
        ];
        let _: () = msg_send![group, release];
        if url == nil {
            return None;
        }
        let path: id = msg_send![url, path];
        if path == nil {
            return None;
        }
        let utf8: *const std::ffi::c_char = msg_send![path, UTF8String];
        if utf8.is_null() {
            return None;
        }
        CStr::from_ptr(utf8)
            .to_str()
            .ok()
            .map(std::path::PathBuf::from)
    }
}

#[cfg(not(target_os = "macos"))]
pub fn app_group_container(_group_id: &str) -> Option<std::path::PathBuf> {
    None
}

/// Takes the window off screen and gives back what it was holding.
///
/// The window is parked rather than destroyed because GPUI leaks it:
/// `MetalRenderer::destroy` is a no-op, and the layer's three drawables go with
/// the window, so every close-and-reopen costs another 28MB that never returns.
/// One window, hidden, holds that flat, and shrinking its drawables while it is
/// away recovers most of what a real teardown would have.
#[cfg(target_os = "macos")]
pub fn park_window(title: &str) {
    unsafe {
        let Some(window) = window_titled(title) else {
            return;
        };
        let _: () = msg_send![window, orderOut: nil];
        if let Some(layer) = metal_layer(window) {
            let _: () = msg_send![layer, setDrawableSize: PARKED_DRAWABLE];
        }
        // Hands back the pages freed by tearing down the frame, which malloc
        // would otherwise sit on for the rest of the process's life.
        malloc_zone_pressure_relief(std::ptr::null_mut(), 0);
    }
}

#[cfg(not(target_os = "macos"))]
pub fn park_window(_title: &str) {}

/// Sizes the drawables back up, ahead of showing the window again. Nothing else
/// will: GPUI only revisits the drawable size on a resize or a display change,
/// and neither happens on the way back from being parked.
#[cfg(target_os = "macos")]
pub fn unpark_window(title: &str) {
    unsafe {
        let Some(window) = window_titled(title) else {
            return;
        };
        let Some(view) = metal_view(window) else {
            return;
        };
        let Some(layer) = metal_layer(window) else {
            return;
        };
        let bounds: NSRect = msg_send![view, bounds];
        let scale: f64 = msg_send![window, backingScaleFactor];
        let size = NSSize {
            width: bounds.size.width * scale,
            height: bounds.size.height * scale,
        };
        if size.width >= 1.0 && size.height >= 1.0 {
            let _: () = msg_send![layer, setDrawableSize: size];
        }
    }
}

#[cfg(not(target_os = "macos"))]
pub fn unpark_window(_title: &str) {}

/// The app's own window. `[NSApp windows]` also holds the status item's window,
/// which carries no title, so matching on the title is enough to tell them apart.
#[cfg(target_os = "macos")]
unsafe fn window_titled(title: &str) -> Option<id> {
    unsafe {
        let windows: id = msg_send![NSApp(), windows];
        let count: u64 = msg_send![windows, count];
        let wanted = NSString::alloc(nil).init_str(title);
        let mut found = None;
        for index in 0..count {
            let window: id = msg_send![windows, objectAtIndex: index];
            let window_title: id = msg_send![window, title];
            let matches: bool = msg_send![window_title, isEqualToString: wanted];
            if matches {
                found = Some(window);
                break;
            }
        }
        let _: () = msg_send![wanted, release];
        found
    }
}

/// GPUI's Metal view is a subview of the content view, not the content view
/// itself, so the layer has to be looked up a level down.
#[cfg(target_os = "macos")]
unsafe fn metal_view(window: id) -> Option<id> {
    unsafe {
        let content: id = msg_send![window, contentView];
        if content == nil {
            return None;
        }
        let subviews: id = msg_send![content, subviews];
        let count: u64 = msg_send![subviews, count];
        for index in 0..count {
            let view: id = msg_send![subviews, objectAtIndex: index];
            let layer: id = msg_send![view, layer];
            if layer != nil {
                let is_metal: bool = msg_send![layer, isKindOfClass: class!(CAMetalLayer)];
                if is_metal {
                    return Some(view);
                }
            }
        }
        None
    }
}

#[cfg(target_os = "macos")]
unsafe fn metal_layer(window: id) -> Option<id> {
    unsafe { metal_view(window).map(|view| msg_send![view, layer]) }
}

#[cfg(target_os = "macos")]
unsafe extern "C" {
    fn malloc_zone_pressure_relief(zone: *mut std::ffi::c_void, goal: usize) -> usize;
}
