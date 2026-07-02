## OpenCode Status Bar

<img width="1286" height="64" alt="OpenCode Status Bar demo" src="https://github.com/user-attachments/assets/a9235da4-2dcc-48ef-9bb9-bf4edb138031" />

> This project is a fork of [claude-status-bar](https://github.com/m1ckc3s/claude-status-bar) by Mick Cesanek, adapted for [OpenCode](https://opencode.ai).

A tiny macOS menu bar app that shows **OpenCode's live status**: a spinner while it's thinking or running a tool, a yellow dot when it's awaiting your permission, and the elapsed time of the current turn. Lightweight, no window, no dock icon, no usage dashboards.

> Built so you can tab away during a long "thinking" stretch and still see, at a glance, whether OpenCode is working, waiting on you, or done.

> [!IMPORTANT]
> **Multi-session support.** When several OpenCode sessions run at once (multiple terminals), the menu bar surfaces the highest-priority one: a session awaiting your permission is never hidden behind one that's thinking. The dropdown lists every live session. Click a session to bring its terminal app to the front.

---

## What it shows

- **Thinking / working** — the icon animates, with a live `1m 1s` timer.
- **Running a tool** — a short label (`Editing`, `Reading`, `Writing`, `Running command`, …).
- **Awaiting permission** — a paused yellow dot.
- **Idle / done** — shows `Done` and rests on a prompt caret.

Everything is controlled from the menu:

- **Show timer:** toggle the elapsed `1m 1s` clock.
- **Play completion sound:** a soft chime whenever a working session finishes (on by default).
- **Color theme:** **Orange** or **System** (adaptive black/white).
- **Version and update:** the menu shows your current version, with a one-click "Update available" when a newer release exists.

## Where it works

| Surface                 | Tracked?                   |
| ----------------------- | -------------------------- |
| OpenCode CLI (terminal) | ✅                         |
| OpenCode Desktop app    | ❌ (terminal-only for now) |

## Requirements

- macOS 12+
- [OpenCode](https://opencode.ai) CLI
- Node.js (for building from source)

## Install

### Option A — DMG (recommended)

1. Download the latest `OpenCodeStatusBar.dmg` from [Releases](https://github.com/outsid3rx/opencode-status-bar/releases).
2. Open it and drag **OpenCode Status Bar** into Applications.
3. Because the DMG is not signed with an Apple Developer ID, macOS will show a Gatekeeper warning. Remove the quarantine flag:

   ```bash
   xattr -dr com.apple.quarantine /Applications/OpenCodeStatusBar.app
   ```

4. Launch **OpenCode Status Bar** once. On first launch it installs the OpenCode plugin for you automatically.
5. Start a new OpenCode session, the icon appears whenever OpenCode is running.

### Updating

Download the latest DMG and drag it into Applications (choose **Replace**). The app refreshes its plugin the next time it starts up, so you don't need to run anything by hand. Your next OpenCode session picks it up.

> [!IMPORTANT]
> **Updated mid-session?** Sessions already open won't show up until they do something (send a prompt) or you start a new `opencode` session.

### Option B — Manual plugin install

The plugin is built from source and not committed to the repo. First build it:

```bash
pnpm install
pnpm build:plugin
```

Then copy the built plugin into OpenCode's plugin directory:

```bash
cp .opencode/plugins/opencode-status-bar.js ~/.config/opencode/plugins/opencode-status-bar.js
```

Finally build the app from source (see [CONTRIBUTING.md](CONTRIBUTING.md)).

## How it works

The app is stateless. OpenCode fires events as it works; the plugin writes those updates to `~/.local/state/opencode/statusbar/state.d/`. The app polls that directory and aggregates every live session into a single icon, a permission dot if one needs you, animating if any session is working, resting when all are idle. It launches itself when OpenCode opens and quits when nothing's running, so there's nothing to manage.

The app's only network call is a once-a-day GitHub release check ([details](PRIVACY.md)).

## Troubleshooting

Icon quitting right after you open it or not showing? See [Troubleshooting](TROUBLESHOOTING.md), most of it is expected behavior, not a bug.

## Uninstall

```bash
rm ~/.config/opencode/plugins/opencode-status-bar.js
rm -rf ~/.local/state/opencode/statusbar
```

Then drag **OpenCode Status Bar** from Applications to the Trash.

## Acknowledgements

This project was originally built as `claude-status-bar` by Mick Cesanek and then adapted for OpenCode. Thank you to everyone who contributed code, fixes, and ideas along the way.

**[See the contributors →](ACKNOWLEDGEMENTS.md)**

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for what fits, what doesn't, and how to build.

## License

MIT
