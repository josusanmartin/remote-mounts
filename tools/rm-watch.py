"""Runs on the server (fed to `python3 -` over ssh) and reports folders whose contents change.

  python3 - ROOT LIMIT

Prints "ready N" once N folders are watched, then one line per changed folder, relative
to ROOT ("" for ROOT itself), batched about once a second. "*" means events were lost and
everything should be re-read. Uses inotify through ctypes, so nothing needs installing;
Linux only. Watches the shallowest folders first, up to LIMIT, skipping hidden and bulky ones,
and keeps room for folders created later.
"""
import ctypes
import os
import select
import struct
import sys
import time

IN_CLOSE_WRITE, IN_MOVED_FROM, IN_MOVED_TO = 0x8, 0x40, 0x80
IN_CREATE, IN_DELETE, IN_Q_OVERFLOW, IN_IGNORED = 0x100, 0x200, 0x4000, 0x8000
IN_ONLYDIR, IN_ISDIR = 0x1000000, 0x40000000
MASK = IN_CLOSE_WRITE | IN_MOVED_FROM | IN_MOVED_TO | IN_CREATE | IN_DELETE
SKIP = {"node_modules", "__pycache__", "site-packages", "venv", "env", "target", "dist"}

root = os.path.realpath(os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else "~"))
limit = int(sys.argv[2]) if len(sys.argv) > 2 else 20000
spare = limit // 4  # for folders created while running

libc = ctypes.CDLL(None, use_errno=True)
fd = libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
if fd < 0:
    print("error inotify unavailable", flush=True)
    sys.exit(2)
paths = {}  # watch descriptor -> folder


def skip(name):
    return name.startswith(".") or name in SKIP


def watch_tree(top, cap):
    """Breadth-first, so a huge deep tree can't use up the budget before its neighbours."""
    queue = [top]
    while queue and len(paths) < cap:
        d = queue.pop(0)
        wd = libc.inotify_add_watch(fd, d.encode(), MASK | IN_ONLYDIR)
        if wd < 0:
            if ctypes.get_errno() == 28:  # ENOSPC: the system-wide watch limit
                return
            continue
        paths[wd] = d
        try:
            with os.scandir(d) as it:
                for e in it:
                    if not skip(e.name) and e.is_dir(follow_symlinks=False):
                        queue.append(e.path)
        except OSError:
            pass


def rel(d):
    return "" if d == root else os.path.relpath(d, root)


watch_tree(root, limit)
print("ready %d" % len(paths), flush=True)

changed = set()
last_flush = time.monotonic()
while True:
    ready, _, _ = select.select([fd], [], [], 1.0)
    if ready:
        try:
            buf = os.read(fd, 65536)
        except BlockingIOError:
            buf = b""
        i = 0
        while i + 16 <= len(buf):
            wd, mask, _cookie, length = struct.unpack_from("iIII", buf, i)
            name = buf[i + 16:i + 16 + length].rstrip(b"\0").decode("utf-8", "surrogateescape")
            i += 16 + length
            if mask & IN_Q_OVERFLOW:
                changed.add("*")
                continue
            d = paths.get(wd)
            if mask & IN_IGNORED:
                paths.pop(wd, None)
                continue
            if d is None or name.endswith(".partial"):  # rclone's in-flight uploads
                continue
            changed.add(rel(d))
            if mask & IN_ISDIR and mask & (IN_CREATE | IN_MOVED_TO) and not skip(name):
                watch_tree(os.path.join(d, name), limit + spare)
    now = time.monotonic()
    if changed and now - last_flush >= 1.0:
        out = ["*"] if "*" in changed else sorted(changed)
        sys.stdout.write("".join(line + "\n" for line in out))
        sys.stdout.flush()
        changed.clear()
        last_flush = now
