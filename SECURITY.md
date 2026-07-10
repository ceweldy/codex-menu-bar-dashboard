# Security

Please report security issues privately through GitHub Security Advisories when available.

This project intentionally keeps machine-specific data outside source control:

- remote helper names, tunnel LaunchAgent labels, and local remote-control URLs live in `~/.codex-menu-bar/config.json`
- tracked server state lives in `~/.codex-menu-bar/servers.json`
- Codex logs and auth files stay under the user's local Codex support directories

Do not include secrets, access tokens, private keys, hostnames, tunnel URLs, or personal machine inventory in issues, examples, or commits.

Remote helper `remoteControlURL` values must use `http` or `https` and point at a loopback host. Treat `~/.codex-menu-bar/servers.json` and configured service commands as trusted local input because start commands run through the user's shell.
