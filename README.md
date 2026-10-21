# Remote Mounts

A macOS menu bar app that mounts SSH servers as local folders, so you can browse and edit them in Finder like local files.

- Pick hosts from `~/.ssh/config` (or `user@host`); uses your normal SSH keys and keychain.
- Per-mount settings: remote folder, local mount folder (`~/Mounts/<name>` by default), mount at launch, read-only, file cache size, folder-listing cache time, extra rclone flags.
- Mount/unmount from the menu bar, automatic reconnect with backoff, clean unmount on quit, stale-mount cleanup after a crash.
- No kernel extension, FUSE or admin rights: each mount is an `rclone nfsmount` over SFTP served to the built-in macOS NFS client.

## Requirements

- macOS 15+
- [rclone](https://rclone.org) (`brew install rclone`)
- Xcode command line tools to build

## Build

```sh
./build.sh           # builds "build/Remote Mounts.app"
./build.sh install   # also installs to ~/Applications and (re)launches it
```

Config lives in `~/Library/Application Support/RemoteMounts/mounts.json`, logs in `~/Library/Logs/RemoteMounts/`.

## Notes on slow links

Tuned for high-latency servers (~250 ms RTT): remote hashing is disabled (otherwise every file open runs `md5sum` over a new SSH login), SFTP connections are capped at 16 and kept open (sshd's default `MaxStartups 10` drops login bursts), and opened files are cached locally.
