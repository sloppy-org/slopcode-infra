# AI model share

Single read-only filesystem at `/Volumes/AI`, served from faepmac1 over NFSv4,
mounted at the same path on every other client in the ITP network. One copy
of the model weights lives on the network; admins write locally on faepmac1,
nobody writes via the network.

## Why

- Workstations cycle through GGUFs in the tens-of-GB range; copying each one
  per host wastes a lot of SSD.
- The institute baseline (OpenAFS, MooseFS) needs a kext on Mac and is flaky.
  NFSv4 is built into macOS and Linux and needs no kext.
- llama.cpp / slopgate read model paths from one env var
  (`LLAMACPP_CACHE_ROOT` in `scripts/_common.sh`), so a single path swap on
  the host moves the whole stack onto the share.

## Layout

```
faepmac1:/Volumes/AI/
  llama.cpp/                     # mirrors $LLAMACPP_CACHE_ROOT layout
    unsloth_Qwen3.6-35B-A3B-GGUF/...
    bartowski_Qwen_Qwen3.6-27B-GGUF/...
    unsloth_Qwen3.5-122B-A10B-GGUF/UD-Q4_K_XL/...
```

The per-user macOS path `~/Library/Caches/llama.cpp` on the server is a
symlink to `/Volumes/AI/llama.cpp` so existing launchagents keep working
without edits.

## Server (faepmac1)

The APFS volume `AI` is in container `disk3` (shared free space with the
system volume, no fixed quota). Export ACL covers ITP LAN
`129.27.161.0/24` and WireGuard `10.77.0.0/24`.

Setup, idempotent:

```bash
bash scripts/install_mac_ai_share_server.sh
bash scripts/migrate_llamacpp_cache_to_share.sh
```

### TCC caveat (one-time)

macOS 14+/26 (Tahoe) blocks writes to `/etc/exports` and
`/Library/Preferences/SystemConfiguration/` from any process that doesn't
have Full Disk Access. On a Homebrew-OpenSSH host the FDA grant must target
the Homebrew binary, not Apple's Remote Login:

System Settings → Privacy & Security → Full Disk Access → `+` →
`/opt/homebrew/sbin/sshd`. Then `brew services restart sshd`. Without this,
`install_mac_ai_share_server.sh` fails with "Operation not permitted" when
it tries to install `/etc/exports`.

## Clients

macOS (autofs, survives reboot):

```bash
sudo bash scripts/install_mac_ai_client.sh
```

Linux (systemd .mount unit):

```bash
sudo bash scripts/install_linux_ai_client.sh
```

Both default to `AI_SHARE_SERVER=faepmac1.tugraz.at` and
`AI_SHARE_MOUNT=/Volumes/AI`. Override per-host if needed.

This local host (workstation reachable only via WireGuard `10.77.0.0/24`)
mounts only for verification — the WG link is too slow for runtime model
load. Production clients are faepmac2 and similar boxes on the 10 GbE ITP
LAN.

## Why NFS and not SMB or HTTP

- **SMB** also works on macOS↔Linux but POSIX/mmap semantics are weaker for
  GGUF mmap, and passwordless guest access requires editing
  `com.apple.smb.server.plist` which hits the same TCC wall as NFS.
- **HTTP** weight serving: llama.cpp `--model-url` downloads-and-caches,
  it does not stream-mmap remote bytes. That gives a bootstrap mirror, not
  shared runtime storage. Skipped.
- **AFS / MooseFS**: institute baseline on Linux but needs a kext on Mac
  and the Mac kext is flaky.

## Recovery

If `/etc/exports` is wiped or the volume is unmounted, re-run
`install_mac_ai_share_server.sh`. The migration script is idempotent: a
second run on a host where `~/Library/Caches/llama.cpp` is already a symlink
is a no-op. Original cache before the swap is preserved under
`~/Library/Caches/llama.cpp.preshare.<timestamp>`; delete only after
confirming services serve from the new path.
