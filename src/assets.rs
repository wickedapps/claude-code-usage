use gpui::{AssetSource, Result, SharedString};
use std::borrow::Cow;

/// The 1024 master from `scripts/make_icon.py`, handed to AppKit as the Dock and
/// app switcher icon. Not served through `AssetSource`: nothing in the UI loads
/// it by name.
pub const DOCK_ICON: &[u8] = include_bytes!("../assets/dock-icon.png");

const FILES: &[(&str, &[u8])] = &[(
    "icons/rotate-cw.svg",
    include_bytes!("../assets/icons/rotate-cw.svg"),
)];

pub struct Assets;

/// Serves this app's own files and falls through to the icon set that ships with
/// gpui-component, which its widgets load by name.
impl AssetSource for Assets {
    fn load(&self, path: &str) -> Result<Option<Cow<'static, [u8]>>> {
        if let Some((_, bytes)) = FILES.iter().find(|(name, _)| *name == path) {
            return Ok(Some(Cow::Borrowed(bytes)));
        }
        gpui_component_assets::Assets.load(path)
    }

    fn list(&self, path: &str) -> Result<Vec<SharedString>> {
        let mut items = gpui_component_assets::Assets.list(path)?;
        for (name, _) in FILES {
            if path.is_empty() || name.starts_with(path) {
                items.push((*name).into());
            }
        }
        Ok(items)
    }
}
