#!/usr/bin/env python3
"""Headless herdr client under a fixed-size PTY.

Usage: attach.py <cols> <rows> <herdr-bin> [client-arg ...]

Spawns `<herdr-bin> client` attached to a pseudo-terminal of the given size,
drains (and discards) everything the client renders so the pipe never blocks,
and stays alive until killed. Inherits the environment (so HERDR_SOCKET_PATH /
XDG_* set by the harness select the bench server).
"""
import os
import sys
import fcntl
import termios
import struct
import signal
import select

def main():
    cols = int(sys.argv[1])
    rows = int(sys.argv[2])
    binpath = sys.argv[3]
    extra = sys.argv[4:] or ["client"]

    pid, master = os.forkpty()
    if pid == 0:
        # Child: becomes the client with the pty as its controlling terminal.
        env = dict(os.environ)
        env["TERM"] = "xterm-256color"
        env["COLUMNS"] = str(cols)
        env["LINES"] = str(rows)
        try:
            os.execvpe(binpath, [binpath] + extra, env)
        except Exception as e:
            os.write(2, f"exec failed: {e}\n".encode())
            os._exit(127)

    # Parent: set the window size on the master pty, then drain output.
    winsz = struct.pack("HHHH", rows, cols, 0, 0)
    fcntl.ioctl(master, termios.TIOCSWINSZ, winsz)

    def _term(_sig, _frm):
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        os._exit(0)

    signal.signal(signal.SIGTERM, _term)
    signal.signal(signal.SIGINT, _term)

    print(f"[attach] client pid={pid} size={cols}x{rows} bin={binpath}", flush=True)

    while True:
        try:
            r, _, _ = select.select([master], [], [], 1.0)
        except (InterruptedError, OSError):
            break
        if master in r:
            try:
                data = os.read(master, 65536)
            except OSError:
                break
            if not data:
                break
        # Reap the child if it died.
        try:
            done, _ = os.waitpid(pid, os.WNOHANG)
            if done == pid:
                break
        except ChildProcessError:
            break

    os._exit(0)

if __name__ == "__main__":
    main()
