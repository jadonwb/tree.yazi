#!/usr/bin/env python3
"""Minimal stdlib PTY driver for the tree-vfs prototype.

Usage: drive.py SPEC.json

SPEC:
  {
    "argv": ["yazi", ...],
    "env":  {"VAR": "..."},
    "keys": ["t", "sleep:0.6", "q"],
    "cols": 120, "rows": 32,      # optional, default 120x32
    "delay": 0.35,                # optional, seconds pumped after each key
    "idle": 15,                   # optional, max seconds to wait for exit
    "out":  "/path/raw.out"       # optional, raw terminal bytes
  }

No tmux; no background daemons. Returns 0 even if yazi had to be terminated,
and writes the raw terminal transcript to the path in "out" when given.
"""
import json
import os
import pty
import select
import subprocess
import sys
import time


def pump(fd, seconds, out):
    end = time.time() + seconds
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try:
                out.extend(os.read(fd, 65536))
            except OSError:
                return


def main():
    spec = json.load(open(sys.argv[1]))
    cols = int(spec.get("cols", 120))
    rows = int(spec.get("rows", 32))
    delay = float(spec.get("delay", 0.35))
    idle = float(spec.get("idle", 15))

    m, s = pty.openpty()
    # Give yazi a real terminal size; a 0x0 winsize makes it misrender.
    import fcntl
    import struct
    import termios

    fcntl.ioctl(s, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    env = dict(os.environ)
    env.update(spec.get("env", {}))
    p = subprocess.Popen(
        spec["argv"], stdin=s, stdout=s, stderr=s, env=env, close_fds=True,
        cwd=spec.get("cwd") or None,
    )
    os.close(s)

    out = bytearray()
    pump(m, 1.5, out)  # startup
    for k in spec["keys"]:
        if k.startswith("sleep:"):
            pump(m, float(k.split(":", 1)[1]), out)
            continue
        try:
            os.write(m, k.encode())
        except OSError:
            break
        pump(m, delay, out)

    end = time.time() + idle
    while p.poll() is None and time.time() < end:
        pump(m, 0.1, out)
    if p.poll() is None:
        p.terminate()
        pump(m, 0.5, out)
        if p.poll() is None:
            p.kill()
    try:
        os.close(m)
    except OSError:
        pass

    data = bytes(out)
    target = spec.get("out")
    if target:
        with open(target, "wb") as fh:
            fh.write(data)
    else:
        sys.stdout.buffer.write(data)


if __name__ == "__main__":
    main()
