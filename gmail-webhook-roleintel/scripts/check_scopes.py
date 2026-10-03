"""Step 1: confirm token.json carries the Drive and Docs scopes. Read-only; never rewrites the token.

Usage: python scripts/check_scopes.py [path/to/token.json]
"""
import json
import sys

REQUIRED = {
    "https://www.googleapis.com/auth/drive",
    "https://www.googleapis.com/auth/documents",
}

path = sys.argv[1] if len(sys.argv) > 1 else "token.json"
with open(path) as f:
    scopes = set(json.load(f).get("scopes") or [])

missing = sorted(REQUIRED - scopes)
print("granted:", ", ".join(sorted(scopes)) or "(none recorded in token.json)")
if missing:
    print("MISSING:", ", ".join(missing))
    print("Re-authorizing needs the account owner; do not regenerate token.json from a script.")
    sys.exit(1)
print("OK: drive + documents present")
