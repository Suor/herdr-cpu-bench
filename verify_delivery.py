#!/usr/bin/env python3
"""Verify the server renders to an attached client when a visible pane changes.

Spawns a herdr client under a PTY, captures everything the client renders, then
triggers output on the server's ACTIVE pane and checks the captured stream grew.
Usage: verify_delivery.py <herdr-bin>
"""
import os, sys, fcntl, termios, struct, select, time, subprocess, json, threading

BIN = sys.argv[1]
COLS, ROWS = 190, 47

captured = bytearray()
lock = threading.Lock()

pid, master = os.forkpty()
if pid == 0:
    env = dict(os.environ); env["TERM"] = "xterm-256color"
    env["COLUMNS"] = str(COLS); env["LINES"] = str(ROWS)
    os.execvpe(BIN, [BIN, "client"], env)
    os._exit(127)

fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))

def drain():
    while True:
        try:
            r, _, _ = select.select([master], [], [], 0.5)
        except OSError:
            return
        if master in r:
            try:
                d = os.read(master, 65536)
            except OSError:
                return
            if not d:
                return
            with lock:
                captured.extend(d)

t = threading.Thread(target=drain, daemon=True); t.start()
time.sleep(4)  # let it attach + initial render

def q(args):
    return subprocess.run([BIN]+args, capture_output=True, text=True).stdout

# Find the active workspace's active tab's focused pane (what the client shows).
panes = json.loads(q(["pane", "list"]))["result"]["panes"]
focused = [p for p in panes if p.get("focused")]
target = (focused[0] if focused else panes[0])["pane_id"]
print(f"active/focused pane = {target}")

with lock:
    before = len(captured)
marker = f"DELIVERY_MARKER_{os.getpid()}"
subprocess.run([BIN, "pane", "run", target, f"echo {marker}"], capture_output=True)
time.sleep(2)
with lock:
    after = len(captured)
    blob = bytes(captured)

print(f"captured bytes: before={before} after={after} delta={after-before}")
print(f"marker visible in client stream: {marker.encode() in blob}")
os.kill(pid, 15)
sys.exit(0 if (after - before) > 0 else 1)
