# SearXNG (local web search for Helpy)

Helpy's `web_search` tool needs a SearXNG endpoint. This repo installs
one as a user-level, localhost-only service.

## Install

| Platform | Command |
| --- | --- |
| macOS   | `scripts/install_mac_searxng_launchagent.sh` |
| Linux   | `scripts/install_linux_searxng_systemd.sh` |
| Windows | `scripts\install_searxng_windows.bat` (Command Prompt) |

The installers run as the unprivileged user. They:

- keep everything in the user profile (no sudo, no admin),
- bind to `127.0.0.1:8888`,
- restart on crash through the platform supervisor,
- keep the default engine set small so local AI agents do not fan
  every query out to CAPTCHA-prone upstreams,
- stay out of the USB bundle path on purpose.

Helper scripts:

```
scripts/setup_searxng.sh           # clone/update SearXNG, venv, settings.yml
scripts/server_start_searxng.sh    # foreground run, smoke test
```

## Wire Helpy to it

Write the local endpoint into Helpy's MCP env file, then restart the
coding agent so `helpy mcp-stdio` respawns with the new variable:

```bash
mkdir -p ~/.config/helpy
printf 'HELPY_SEARXNG_BASE_URL=http://127.0.0.1:8888\n' > ~/.config/helpy/mcp.env
```

## Layout

| Item | Default path |
| --- | --- |
| SearXNG checkout | `~/code/searxng` when `~/code` exists, else `~/.local/searxng/src` |
| Python env | `~/.local/searxng/.venv` |
| Config | `~/.config/searxng/settings.yml` |
| Endpoint | `http://127.0.0.1:8888` |

The generated profile treats localhost as untrusted client traffic:
autocomplete off by default, longer local suspensions on engine
failures, and a default engine allowlist limited to AOL, Wikipedia,
Bing, Mojeek, SearchMySite, Wiby, and Presearch. Enable broader or
more fragile engines explicitly per host.

## Platform notes

- **macOS:** `launchd` background agent in the per-user GUI domain.
  User-level, not tied to a visible terminal.
- **Linux:** `systemd --user` unit. The installer attempts
  `loginctl enable-linger` so the service survives logout and boot
  without root where polkit allows it.
- **Windows:** Task Scheduler job. First tries passwordless S4U mode
  ("run whether logged on or not"). If local policy blocks that, falls
  back to a plain logon task and prints the limitation rather than
  hiding it.
