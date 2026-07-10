# Architecture

This is a small native macOS Swift Package with one executable target.

## Runtime Data Flow

1. `DashboardController` owns the menu-bar item, popover, periodic refresh timer, and user actions.
   - `SettingsWindowController` provides native local branding controls and shortcuts to dashboard data files.
2. Collectors gather current state:
   - `ServerCollector` finds local web servers, merges them with configured services and the user's registry, and samples CPU, memory, uptime, listener count, and port conflicts.
   - `RemoteProjectCollector` reads Codex remote connection state and optional local remote-helper config.
   - `RemoteServiceController` checks and controls user LaunchAgents over non-interactive SSH, probes health, and fetches remote logs.
   - `TailscalePublishController` reports and changes opt-in Serve or Funnel exposure for configured ports.
   - `CodexUsageCollector` reads the local Codex usage event cache.
   - `CaffeinateController` and `ClosedLidAwakeController` read and change power state.
3. `ActivityStore` records durable lifecycle events while the watchdog evaluates configured services without fighting intentional user stops.
4. A `DashboardSnapshot` is rendered into both the menu and popover. Sections can be collapsed, and the popover body scrolls independently under the fixed power controls.

## Local Files

- `~/.codex-menu-bar/config.json`: optional branding, managed services, stacks, publishing targets, and remote helpers.
- `~/.codex-menu-bar/servers.json`: local server registry created by the app.
- `~/.codex-menu-bar/activity.json`: recent lifecycle and watchdog events.
- `~/.codex-menu-bar/remote-logs/`: copies of logs explicitly fetched from managed remote services.
- `~/.codex-menu-bar/*.log`: LaunchAgent and runtime logs.

## Security Boundary

The app does not ship or require cloud credentials. It reads local Codex state and runs local macOS commands. Remote actions use existing SSH configuration with password prompts disabled. Tailscale publishing is disabled by default, and Funnel requires a visible confirmation because it creates public internet access. Machine-specific hostnames, tunnel labels, URLs, and other private settings belong in local config, not source.
