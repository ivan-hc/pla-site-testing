#!/usr/bin/env python3
"""Select catalog apps that are missing real screenshots.

Prints a JSON array of app file names (AM app IDs) whose `# SCREENSHOTS:` line
is missing, empty, or still holds the `contribute_ss.webp` placeholder.

Exclusions are read from `app-screenshot-blacklist` next to this script.
"""
import os
import re
import sys
import random

APPS_DIR = sys.argv[1] if len(sys.argv) > 1 else "apps"
BLACKLIST = os.path.join(os.path.dirname(__file__), "app-screenshot-blacklist")
PLACEHOLDER = re.compile(r"contribute_ss")

blacklist = set()
with open(BLACKLIST, "r", errors="replace") as fh:
    for line in fh:
        line = line.strip()
        if line and not line.startswith("#"):
            blacklist.add(line)

candidates = []
for fname in sorted(os.listdir(APPS_DIR)):
    if fname.startswith(".") or fname.endswith("~"):
        continue
    if fname in blacklist:
        continue
    try:
        text = open(os.path.join(APPS_DIR, fname), "r", errors="replace").read()
    except OSError:
        continue
    m = re.search(r"^#\s*SCREENSHOTS\s*:\s*(.*?)\s*$", text, re.M)
    if not m or not m.group(1).strip() or PLACEHOLDER.search(m.group(1)):
        candidates.append(fname)

if len(sys.argv) > 2 and sys.argv[2] == "shuffle":
    random.shuffle(candidates)

print("\n".join(candidates))