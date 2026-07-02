# Troubleshooting

**You don't open this app, it opens itself.** The only time you launch it by hand is once, right after install, so it can install the OpenCode plugin. After that it starts itself whenever an OpenCode session is running and quits when none is. So opening it from Finder or Spotlight with no session active can look like it launches and immediately quits. That is expected, not a crash: just start an OpenCode session and the icon appears on its own. Upgrades self-heal: drop the new version into Applications and it refreshes its plugin the next time it starts up.

**Updated (or just installed) while OpenCode sessions were already running?** Those sessions only show up once they do something after the new plugin is in place, so the menu can look empty even with terminals open. Send a prompt in each one, or start a fresh `opencode` session, and they appear. (Restarting the terminal works too, since that starts a new session.)

**The icon doesn't appear at all?**

- Make sure an OpenCode session is actually running. Start a new session (or restart OpenCode) and the bar appears automatically.
- A session that was already running _before_ you installed gets picked up once it does something, but starting a fresh session is the reliable way to bring the bar up the first time.
- Confirm it's running with `pgrep -x OpenCodeStatusBar`: a number means it's running (it may just be hidden), no output means it exited because no OpenCode session is active.
- If first-launch setup never took, copy the plugin manually: `cp "/Applications/OpenCodeStatusBar.app/Contents/Resources/opencode-status-bar.ts" ~/.config/opencode/plugins/`

---

Back to the [README](README.md).
