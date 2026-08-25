# Claude Code Usage

<img src="assets/dock-icon.png" width="128" height="128" alt="Claude Code Usage">

A macOS menu bar app that shows how much Claude Code you have left. The menu bar reads `5h 62% · 7d 41%`, the percentages left in the 5-hour and weekly windows, and refreshes itself every minute. Opening the menu shows those same remaining percentages with how long until each window resets, and from there you can open the window, force a refresh, or quit.

The window has the same two limits along the top, plus the Opus weekly window, which does not fit in the menu bar. Under them is a table of input, output, cache, and total tokens per day, week, month, session, and 5-hour block, summed from the JSONL transcripts in `~/.claude/projects`.

The Dock icon follows the window. While the window is up the app is a regular one, with a Dock tile, a Cmd-Tab entry, and its own menu bar. Closing the window parks it as an accessory, leaving the menu bar item as the only thing on screen.

Built with [GPUI](https://gpui.rs/) and [gpui-component](https://longbridge.github.io/gpui-component/). Unofficial, and not affiliated with Anthropic.

The limits come from Anthropic's OAuth usage endpoint. The app sends the token Claude Code already keeps in your login keychain, so there is no second login here. If Claude Code is signed out, or that token is rejected, the window says "Not logged in" and drops any numbers it had been showing. `claude auth status` can still report a login after the token is dead, so a 401 from the usage API is what actually ends the session.

That token is sent only to `https://api.anthropic.com/api/oauth/usage`. Transcripts stay on disk. There is no extra account, no telemetry, and no other server. The endpoint is not a public API, so a Claude Code update can change the shape of the response or stop accepting the request.

## Requirements

- macOS
- Rust 1.88 or newer (`rustup`), edition 2024
- [Claude Code](https://code.claude.com/) installed and on your PATH
- Xcode command line tools, with the Metal toolchain if the first build asks for it:

```sh
xcode-select --install
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
xcodebuild -downloadComponent MetalToolchain
```

## Run

```sh
cargo run
```

GPUI and gpui-component are git dependencies pinned in `Cargo.toml`, so the first build clones both and compiles them. Expect it to take a while. `Cargo.lock` should be committed with the rest of the tree so everyone builds the same revisions.

```sh
cargo build --release
./target/release/claude-usage
```

Refresh from the header button or the menu bar. Closing the window leaves the app in the menu bar. Quit from there, or with Cmd-Q while the window has focus.

## Idling in the menu bar

Closing the window parks it rather than destroying it, and the app settles at about 0.3% CPU and a 64MB footprint, against 1.1% and 80MB with the window up.

Parking, rather than closing, is deliberate. GPUI leaks a window on teardown: `MetalRenderer::destroy` is a no-op and the layer's three drawables go with it, so every close-and-reopen costs another 28MB that never came back. Four cycles reached 171MB. Keeping the one window and taking it off screen holds that flat. While it is parked its drawables shrink to 1x1, which is what returns the 21.5MB of GPU surfaces, and `AppView` ignores store updates so nothing asks for a frame that will never be shown. A frame requested by a parked window is not free: it costs a CoreAnimation commit and an AppKit display cycle, which on its own was worth 2% CPU.

The limits are polled every minute with the window open and every five with it closed. Both intervals are in `src/store.rs`. The user agent, which needs `claude --version` and so a login shell and a Node start, is read once per run rather than once per poll.

## Distribution

`scripts/bundle.sh` builds `Claude Code Usage.app`, signs it with your Developer ID, and packs a disk image (plus a zip). Set your own identifiers first:

```sh
cp scripts/release.env.example scripts/release.env
```

Fill in a bundle id you own. `release.env` is ignored by git, and the script reads your signing certificate from your keychain, so nothing about your developer account is ever committed. Then:

```sh
sh scripts/bundle.sh
```

To notarize as well, create a notarytool profile once. It stores your app-specific password in your login keychain rather than in the repo:

```sh
xcrun notarytool store-credentials <profile> \
  --apple-id you@example.com --team-id <TEAM_ID> --password <app-specific>
```

Put that profile name in `release.env` as `NOTARY_PROFILE` and run the script again.

The app is signed with the hardened runtime, which notarization requires, and with no entitlements. It is deliberately not sandboxed: it runs the `claude` CLI through a login shell and reads Claude Code's keychain item, and the sandbox has no entitlement that permits either.

## Icon

The Claude Code mark is from [thesvg.org](https://thesvg.org/icon/claude-code) (MIT) and lives in `assets/app-icon.svg`. The refresh icon is [Lucide](https://lucide.dev)'s `rotate-cw` (ISC). To regenerate the bundle icon after editing the mark:

```sh
python3 scripts/make_icon.py
```

That renders the mark onto the macOS icon grid, an 824x824 rounded body inside a 1024x1024 canvas, and writes `assets/dock-icon.png`, the 1024 master the app hands AppKit for the Dock and the app switcher, plus `assets/AppIcon.icns`, which is what Finder shows on the bundle. Nothing rounds or insets the artwork on the way, so the padding, corner curve, and shadow have to be baked in or the icon sits larger than its neighbours. The corner and shadow constants in the script are fitted to the silhouette macOS applies to its own app icons, within 3px at 1024.

## License

This project's source is [ISC](LICENSE). GPUI and gpui-component are Apache-2.0. A git checkout of Zed currently also links GPL-3.0 tracing crates into the binary, which may apply if you redistribute a build.
