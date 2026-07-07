# Architecture

This is a small native macOS Swift Package with one executable target.

## Runtime Data Flow

1. `DashboardController` owns the menu-bar item, popover, periodic refresh timer, and user actions.
2. Collectors gather current state:
   - `ServerCollector` finds local web servers and merges them with the user's server registry.
   - `RemoteProjectCollector` reads Codex remote connection state and optional local remote-helper config.
   - `CodexUsageCollector` reads the local Codex usage event cache.
   - `CaffeinateController` and `ClosedLidAwakeController` read and change power state.
3. A `DashboardSnapshot` is rendered into both the menu and popover.

## Local Files

- `~/.codex-menu-bar/config.json`: optional machine-specific remote helper settings.
- `~/.codex-menu-bar/servers.json`: local server registry created by the app.
- `~/.codex-menu-bar/*.log`: LaunchAgent and runtime logs.

## Security Boundary

The app does not ship or require cloud credentials. It reads local Codex state and runs local macOS commands. Machine-specific hostnames, tunnel labels, URLs, and other private settings belong in local config, not source.

Generated server start commands are launched directly as structured argv. Fallback commands from process metadata or the local registry require confirmation before shell execution. Remote-helper probes accept only local HTTP(S) loopback URLs.
