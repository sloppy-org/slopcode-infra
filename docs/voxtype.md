# Voxtype (push-to-talk dictation)

[`peteonrails/voxtype`](https://github.com/peteonrails/voxtype) is the
Linux-native push-to-talk dictation daemon. The helpers below wrap the
upstream release artefacts so the user does not have to read the
upstream README before hitting the F-key.

```
scripts/install_voxtype_linux.sh    # systemd --user, deb/rpm fallback
scripts/install_voxtype_mac.sh      # documented manual path (no Mac binary upstream)
scripts/install_voxtype_windows.bat # documented manual path (no Windows binary upstream)
```

The Linux installer detects GPU class (CUDA, Vulkan, or CPU-only) and
pulls the matching release binary. It points the daemon at the local
whisper server on `127.0.0.1:8427` by default and registers a
`systemd --user` service.

macOS and Windows scripts surface the upstream non-goal of those
platforms instead of pretending support exists.
