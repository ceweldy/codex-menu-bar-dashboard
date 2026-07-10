# Open-Source Audit

Last reviewed: 2026-07-10

## Scope

Reviewed the Swift package, menu-bar source, installer scripts, README, example config, license, and security notes.

## Findings

- No API keys, bearer tokens, private keys, service credentials, or auth files were found in source.
- Machine-specific remote helper details were removed from source and moved to external local config.
- Product labels and replacement icon paths are configurable; the public defaults do not name a personal host or deployment.
- The native Settings window writes appearance preferences only to the external local configuration file.
- The default app bundle identifier and LaunchAgent label are generic and can be overridden with environment variables.
- Build products, runtime logs, server registry data, and local config are ignored by git.
- Remote-helper probe URLs are restricted to local HTTP(S) loopback hosts.
- GitHub Dependabot metadata is present under `.github/`.

## Local-only Data

Store machine-specific settings in:

```text
~/.codex-menu-bar/config.json
```

Do not commit local Codex logs, auth files, remote-control URLs, tunnel LaunchAgent labels, hostnames, or private machine inventory.

## Verification Commands

```zsh
swift build -c release
python3 -m json.tool Examples/config.example.json >/dev/null
rg -n --hidden --glob '!/.build/**' --glob '!build/**' 'api[_-]?key|secret|token|password|authorization|bearer|private[_-]?key|BEGIN (RSA|OPENSSH)' .
```
