//! The menu bar item: a text readout of the remaining limits, and the menu it
//! drops down. GPUI has no binding for `NSStatusItem`, so this talks to AppKit
//! the same way `macos.rs` does for the application icon.
#![allow(unexpected_cfgs)]

/// Picked from the status item's menu.
#[derive(Clone, Copy, Debug)]
pub enum MenuAction {
    Refresh,
    Open,
    Quit,
}

#[cfg(target_os = "macos")]
pub use platform::{install, set_limits, set_title};

#[cfg(target_os = "macos")]
mod platform {
    use super::MenuAction;
    use crate::limits::{QuotaLimits, QuotaWindow};
    use cocoa::base::{NO, YES, id, nil};
    use cocoa::foundation::NSString;
    use objc::declare::ClassDecl;
    use objc::runtime::{Class, Object, Sel};
    use objc::{class, msg_send, sel, sel_impl};
    use std::cell::RefCell;

    /// `NSVariableStatusItemLength`: the item is only as wide as its title.
    const VARIABLE_LENGTH: f64 = -1.0;
    /// A system font asked for size 0 comes back at the default size.
    const DEFAULT_FONT_SIZE: f64 = 0.0;
    /// `NSFontWeightRegular`.
    const FONT_WEIGHT_REGULAR: f64 = 0.0;
    /// Name of the class declared below to receive the menu's actions.
    const TARGET_CLASS: &str = "ClaudeUsageStatusBarTarget";

    struct StatusBar {
        item: id,
        five_hour: id,
        weekly: id,
        separator: id,
        limits: Option<QuotaLimits>,
    }

    thread_local! {
        /// Every call here runs on the main thread and the item lives until the
        /// process exits, so a thread local is enough to hold both of these.
        static STATUS_ITEM: RefCell<Option<StatusBar>> = const { RefCell::new(None) };
        static ON_ACTION: RefCell<Option<Box<dyn Fn(MenuAction)>>> = const { RefCell::new(None) };
    }

    /// Adds the item to the menu bar. Call once, on the main thread, after
    /// AppKit has finished launching.
    pub fn install(on_action: impl Fn(MenuAction) + 'static) {
        ON_ACTION.with(|slot| *slot.borrow_mut() = Some(Box::new(on_action)));

        unsafe {
            let bar: id = msg_send![class!(NSStatusBar), systemStatusBar];
            let item: id = msg_send![bar, statusItemWithLength: VARIABLE_LENGTH];
            // The status bar only holds the item weakly. Letting our reference
            // go would take it straight back out of the menu bar.
            let item: id = msg_send![item, retain];

            // Digits that share a width, so the item stops shifting its
            // neighbours around every time a percentage ticks down.
            let button: id = msg_send![item, button];
            let font: id = msg_send![
                class!(NSFont),
                monospacedDigitSystemFontOfSize: DEFAULT_FONT_SIZE
                weight: FONT_WEIGHT_REGULAR
            ];
            let _: () = msg_send![button, setFont: font];

            let target: id = msg_send![action_target_class(), new];
            let menu: id = msg_send![class!(NSMenu), new];
            // Limit lines are filled in when the menu opens, from whatever the
            // store last handed us. Hidden until then so an empty pair does not
            // sit above Refresh on the first click.
            let five_hour = add_info_item(menu);
            let weekly = add_info_item(menu);
            let separator: id = msg_send![class!(NSMenuItem), separatorItem];
            let _: () = msg_send![separator, setHidden: YES];
            let _: () = msg_send![menu, addItem: separator];
            add_item(menu, "Refresh", sel!(refreshClicked:), target);
            add_item(menu, "Open Claude Code Usage", sel!(openClicked:), target);
            let actions_separator: id = msg_send![class!(NSMenuItem), separatorItem];
            let _: () = msg_send![menu, addItem: actions_separator];
            add_item(menu, "Quit", sel!(quitClicked:), target);
            let _: () = msg_send![menu, setDelegate: target];
            let _: () = msg_send![item, setMenu: menu];

            STATUS_ITEM.with(|slot| {
                *slot.borrow_mut() = Some(StatusBar {
                    item,
                    five_hour,
                    weekly,
                    separator,
                    limits: None,
                });
            });
        }
    }

    /// Replaces the text shown in the menu bar. A no-op before `install`.
    pub fn set_title(title: &str) {
        STATUS_ITEM.with(|slot| {
            let slot = slot.borrow();
            let Some(bar) = slot.as_ref() else {
                return;
            };
            unsafe {
                let button: id = msg_send![bar.item, button];
                let text = NSString::alloc(nil).init_str(title);
                let _: () = msg_send![button, setTitle: text];
                // `title` is a copying property, so ours is spare now.
                let _: () = msg_send![text, release];
            }
        });
    }

    /// Keeps a copy of the windows so the menu can write remaining and reset
    /// times at the moment it opens, not at the last poll.
    pub fn set_limits(limits: Option<QuotaLimits>) {
        STATUS_ITEM.with(|slot| {
            if let Some(bar) = slot.borrow_mut().as_mut() {
                bar.limits = limits;
            }
        });
    }

    unsafe fn add_item(menu: id, title: &str, action: Sel, target: id) {
        unsafe {
            let text = NSString::alloc(nil).init_str(title);
            // No key equivalent: an accessory app has no menu bar of its own, so
            // a shortcut here would only work while the menu is already open.
            let empty = NSString::alloc(nil).init_str("");
            let item: id = msg_send![class!(NSMenuItem), alloc];
            let item: id = msg_send![item, initWithTitle: text action: action keyEquivalent: empty];
            let _: () = msg_send![item, setTarget: target];
            let _: () = msg_send![menu, addItem: item];
            // The menu retains the item, and the item copied both strings.
            let _: () = msg_send![item, release];
            let _: () = msg_send![text, release];
            let _: () = msg_send![empty, release];
        }
    }

    /// Disabled, no action: the line is only there to be read. Starts hidden.
    unsafe fn add_info_item(menu: id) -> id {
        unsafe {
            let item: id = msg_send![class!(NSMenuItem), new];
            let _: () = msg_send![item, setEnabled: NO];
            let _: () = msg_send![item, setHidden: YES];
            let _: () = msg_send![menu, addItem: item];
            // `new` was +1 and the menu retained; drop our claim.
            let _: () = msg_send![item, release];
            item
        }
    }

    fn apply_info_items() {
        STATUS_ITEM.with(|slot| {
            let slot = slot.borrow();
            let Some(bar) = slot.as_ref() else {
                return;
            };
            unsafe {
                let five_shown = apply_info_item(
                    bar.five_hour,
                    "5-hour",
                    bar.limits
                        .as_ref()
                        .and_then(|limits| limits.five_hour.as_ref()),
                );
                let weekly_shown = apply_info_item(
                    bar.weekly,
                    "Weekly",
                    bar.limits
                        .as_ref()
                        .and_then(|limits| limits.seven_day.as_ref()),
                );
                let hide_separator = if five_shown || weekly_shown { NO } else { YES };
                let _: () = msg_send![bar.separator, setHidden: hide_separator];
            }
        });
    }

    unsafe fn apply_info_item(item: id, label: &str, window: Option<&QuotaWindow>) -> bool {
        unsafe {
            let Some(window) = window else {
                let _: () = msg_send![item, setHidden: YES];
                return false;
            };
            let title = format!(
                "{label}: {:.0}% left, {}",
                window.remaining,
                window.resets_label()
            );
            let text = NSString::alloc(nil).init_str(&title);
            let _: () = msg_send![item, setTitle: text];
            let _: () = msg_send![text, release];
            let _: () = msg_send![item, setHidden: NO];
            true
        }
    }

    /// Objective-C wants a target object with a selector per menu item, so
    /// declare a bare `NSObject` subclass that forwards each one to `ON_ACTION`.
    /// The same object is the menu's delegate, so it can rewrite the limit
    /// lines each time the menu is about to appear.
    fn action_target_class() -> &'static Class {
        if let Some(existing) = Class::get(TARGET_CLASS) {
            return existing;
        }
        let mut decl =
            ClassDecl::new(TARGET_CLASS, class!(NSObject)).expect("could not declare menu target");
        unsafe {
            decl.add_method(
                sel!(refreshClicked:),
                refresh_clicked as extern "C" fn(&Object, Sel, id),
            );
            decl.add_method(
                sel!(openClicked:),
                open_clicked as extern "C" fn(&Object, Sel, id),
            );
            decl.add_method(
                sel!(quitClicked:),
                quit_clicked as extern "C" fn(&Object, Sel, id),
            );
            decl.add_method(
                sel!(menuNeedsUpdate:),
                menu_needs_update as extern "C" fn(&Object, Sel, id),
            );
        }
        decl.register()
    }

    extern "C" fn refresh_clicked(_: &Object, _: Sel, _: id) {
        dispatch(MenuAction::Refresh);
    }

    extern "C" fn open_clicked(_: &Object, _: Sel, _: id) {
        dispatch(MenuAction::Open);
    }

    extern "C" fn quit_clicked(_: &Object, _: Sel, _: id) {
        dispatch(MenuAction::Quit);
    }

    extern "C" fn menu_needs_update(_: &Object, _: Sel, _: id) {
        apply_info_items();
    }

    fn dispatch(action: MenuAction) {
        ON_ACTION.with(|slot| {
            // Borrowed, not taken: the handler stays installed for the next click.
            if let Some(handler) = slot.borrow().as_ref() {
                handler(action);
            }
        });
    }
}

#[cfg(not(target_os = "macos"))]
pub fn install(_on_action: impl Fn(MenuAction) + 'static) {}

#[cfg(not(target_os = "macos"))]
pub fn set_title(_title: &str) {}

#[cfg(not(target_os = "macos"))]
pub fn set_limits(_limits: Option<crate::limits::QuotaLimits>) {}
