# Codex Menu Bar Dashboard

Native macOS menu-bar dashboard for local Codex work.

It shows:

- Codex rate-limit usage from the local Codex app logs, including the short window, weekly usage, and reset times.
- Project web servers detected from local listening TCP ports.
- Start, stop, open, and remove controls for tracked local servers.
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

The server registry lives at `~/.codex-menu-bar/servers.json`. Detected servers are inferred from project roots with markers such as `package.json`, `pyproject.toml`, `manage.py`, or `Gemfile`. When a detected server is stopped from the menu, it is tracked so it can be started again later.

## Local configuration

Machine-specific values are intentionally not stored in source. Put optional remote-helper settings in:

```text
~/.codex-menu-bar/config.json
```

Use [Examples/config.example.json](Examples/config.example.json) as a template. A remote helper can match a Codex remote connection by hostname, alias, display name, or host id, then optionally restart a local tunnel LaunchAgent and probe a local remote-control URL.
Remote-control URLs are intentionally limited to local HTTP(S) loopback hosts such as `http://127.0.0.1:12345/`.

You can also point the app at another config file:

```zsh
CODEX_MENU_BAR_CONFIG=/path/to/config.json ./build/CodexMenuBar.app/Contents/MacOS/CodexMenuBar
```

## Open-source safety

The repository should contain only source, scripts, docs, and placeholder examples. Do not commit:

- `~/.codex-menu-bar/config.json`
- `~/.codex-menu-bar/servers.json`
- local build outputs under `.build/` or `build/`
- Codex logs, tokens, auth files, or machine-specific LaunchAgent files

Generated web-server start commands are launched without a shell when possible. Fallback commands from the local registry or detected process metadata require confirmation before they are run through the shell.
