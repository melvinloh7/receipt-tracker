"""Prints the release notes for one build, taken from CHANGELOG.md.

Usage: python3 scripts/release_notes.py <build number>
Falls back to the latest commit message if the changelog has no entry yet.
"""
import pathlib
import re
import subprocess
import sys

build = sys.argv[1]
text = (pathlib.Path(__file__).resolve().parent.parent / "CHANGELOG.md").read_text()
match = re.search(rf"^## Build {re.escape(build)}\b.*?$(.*?)(?=^## Build |\Z)", text, re.S | re.M)
if match:
    notes = match.group(1).strip()
else:
    notes = "- " + subprocess.run(
        ["git", "log", "-1", "--format=%s"], capture_output=True, text=True
    ).stdout.strip()

print(notes)
print()
print("Download receipt-tracker.apk below and open it on your phone to install or update.")
print("Full history: CHANGELOG.md in the repo.")
