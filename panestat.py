#!/usr/bin/env python3
"""Print compact per-pane revision/agent snapshot from `herdr pane list` JSON on stdin."""
import sys, json
panes = json.load(sys.stdin)["result"]["panes"]
parts = []
for p in sorted(panes, key=lambda x: x["pane_id"]):
    tail = p["pane_id"].split("-")[-1]
    rev = p.get("revision")
    ag = p.get("agent")
    parts.append(f"{tail}:{rev}" + (f"({ag})" if ag else ""))
print(" ".join(parts))
