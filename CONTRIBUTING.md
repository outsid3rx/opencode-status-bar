# Contributing

Thanks for your interest. This is a tiny menu bar app and I'd like to keep it that way.

It does one thing: show OpenCode's live status. It stays local (the only network call is a daily update check), free (no API key, no spend), and small (a status bar, not a dashboard).

## What's welcome

Bug fixes, performance wins, animation and visual polish, better session focus, and compatibility fixes (macOS versions, CPU architectures, terminals).

Also the [known issues and suggestions](https://github.com/outsid3rx/opencode-status-bar/issues): it tracks proposed enhancements, and anything marked in scope there is open to pick up.

## Won't be merged

- Sending your conversation, files, or project to any API or relay.
- Anything that costs money or needs an API key.
- Usage meters, cost dashboards, analytics, or telemetry.
- Heavy work in the plugin. It runs on every event, so it writes one small state file and exits: no network, no per-prompt API calls.
- Hardcoding for one locale, provider, relay, or terminal.
- New settings stores or dependencies for a minor feature when what's already there works.

## Building

You'll need macOS 12+, the Swift toolchain (Xcode Command Line Tools), and Node.js.

```bash
./build.sh          # -> build/OpenCodeStatusBar.app
./build.sh --dmg    # also builds a .dmg
```

Signing and notarization use the maintainer's Developer ID; without it you get an ad-hoc build, which is fine for testing. Launch it, start an OpenCode session, and the icon appears.

## Tests

```bash
corepack enable
pnpm install
pnpm test
pnpm typecheck
pnpm lint
pnpm format:check
```

## Commits

[Conventional Commits](https://www.conventionalcommits.org/): `feat`, `fix`, `chore`, `refactor`, `style`, `docs`, `perf`. Branches: `type/kebab-case-description`.

## License

MIT. By contributing, you agree your contributions are licensed under it.
