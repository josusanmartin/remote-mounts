# Remote Mounts

A macOS menu bar app that mounts SSH servers as local folders, so you can browse and edit them in Finder like local files.

- **Add servers** from your `~/.ssh/config` (or `user@host`); logs in with your normal SSH keys and keychain.
- **Passphrase-protected keys**: the first time a server needs a locked key, a prompt asks for the passphrase once, adds the key to the macOS ssh-agent and can save it in your Keychain; after a restart it's reloaded silently. The passphrase never touches disk or rclone's config.
- **Menu bar panel**: a switch per server, click a row to mount and open it in Finder, hover for Finder / Terminal / more actions, Retry on failures.
- **Safe unmount and quit**: pending uploads finish first (with a "Quit Now" escape); anything cut short resumes on the next mount.
- **Live activity**: uploads in progress, transfer speed, local cache usage.
- **Resilient**: reconnects with backoff, retries immediately when the network comes back or the Mac wakes, cleans up stale mounts after a crash, refuses to run twice.
- **Notifications** when a server disconnects, reconnects or fails to mount, with plain-English reasons ("The server refused your SSH key…").
- **Remote folder browser**, Test Connection, Open in Terminal (ssh into the mounted folder), built-in log viewer.
- **Per-server settings**: remote folder, local mount folder (`~/Mounts/<name>` by default), mount at launch, read-only, file cache size, folder-listing cache time, extra rclone flags (with the full command shown).
- **Settings**: open at login, keep in Dock (handy when the notch hides menu bar icons), notifications.
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

Unmounting always goes through the running rclone first: killing rclone before the kernel unmounts leaves an NFS mount whose server is gone, and unmounting that hangs. If that happens anyway (a crash), the app stands in a throwaway `rclone serve nfs :memory:` on the old port so the unmount can finish.
