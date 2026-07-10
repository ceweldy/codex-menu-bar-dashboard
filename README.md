# Codex Menu Bar Dashboard

Native macOS menu-bar dashboard for local Codex work.

It shows:

- Codex rate-limit usage from the local Codex app logs, including the short window, weekly usage, and reset times.
- Project web servers detected from local listening TCP ports.
- Start, stop, open, and remove controls for tracked local servers.
- Named project stacks that can start or stop several local and remote services together.
- Managed remote services with live health, CPU, memory, uptime, restart, and downloaded-log controls.
- Per-service watchdog modes: off, notify-only, or notify and automatically restart after a failure.
- Opt-in Tailscale Serve and Funnel controls for private-tailnet or explicitly confirmed public sharing.
- A durable activity timeline for service, stack, watchdog, power, and sharing changes.
- A native Settings window for dashboard labels, a replacement menu-bar icon, and quick access to local configuration and history files.
- A vertically scrollable dashboard that stays within the usable screen height even with many servers or remote projects.
- A fixed configurable header with always-visible Caffeinate and closed-lid controls, live server/remote status pills, and a replaceable monochrome menu-bar logo that follows the macOS appearance.
- Parallel full-state refreshes plus five-second local server and power checks while the dashboard is open; unchanged state does not redraw the popover.
- Bulk Stop All and Clear Stopped actions, copied localhost URLs, project-folder shortcuts, and logs for servers launched by the dashboard.
- A right-click quick-actions menu for usage, power, remote hosts, and server controls.
- Power toggles for `caffeinate` and closed-lid awake mode.
- Optional remote-host status helpers configured from a local JSON file.

Install or restart it:

```zsh
./scripts/install-launch-agent.sh
```

Allow the closed-lid awake toggle to run without a password prompt:

```zsh
./scripts/install-pmset-sudoers.sh
```

Remove that passwordless permission:

```zsh
sudo ./scripts/uninstall-pmset-sudoers.sh
```

Remove the launch agent:

```zsh
./scripts/uninstall-launch-agent.sh
```

The server registry lives at `~/.codex-menu-bar/servers.json`. Detected servers are inferred from project roots with markers such as `package.json`, `pyproject.toml`, `manage.py`, or `Gemfile`. When a detected server is stopped from the menu, it is tracked so it can be started again later. Removing a running server first stops its process tree and listener, then removes it from the dashboard; a server that cannot be stopped stays visible with an error instead of being silently hidden.

## Local configuration

Machine-specific values are intentionally not stored in source. Put managed local services, remote services, project stacks, publishing targets, and optional remote helpers in:

```text
~/.codex-menu-bar/config.json
```

Use [Examples/config.example.json](Examples/config.example.json) as a template. Remote service actions use non-interactive SSH and a user LaunchAgent on the target Mac. Publishing remains off until its Tailnet or Public button is selected; public Funnel mode also requires a confirmation in the app.

Remote-control helper probes accept only local HTTP(S) loopback URLs such as `http://127.0.0.1:12345/`. Service start commands come from the user's local configuration or registry and should be treated as trusted shell input.

Branding is optional. `branding.name` and `branding.subtitle` replace the generic dashboard labels, while `branding.iconPath` can point to another local transparent template image. If no custom image is configured, the bundled monochrome logo is used.

Open **Settings…** from the menu-bar icon's right-click menu or use the **Settings** button in the dashboard footer. Appearance changes are saved locally and applied immediately.

The dashboard keeps intentional stops paused in the watchdog so a service does not immediately relaunch after you stop it. Starting it again resumes monitoring. Activity history is stored separately at `~/.codex-menu-bar/activity.json` and can be opened or cleared from the dashboard.

You can also point the app at another config file:

```zsh
CODEX_MENU_BAR_CONFIG=/path/to/config.json ./build/CodexMenuBar.app/Contents/MacOS/CodexMenuBar
```

## Open-source safety

The repository should contain only source, scripts, docs, and placeholder examples. Do not commit:

- `~/.codex-menu-bar/config.json`
- `~/.codex-menu-bar/servers.json`
- `~/.codex-menu-bar/activity.json`
- local build outputs under `.build/` or `build/`
- Codex logs, tokens, auth files, or machine-specific LaunchAgent files
