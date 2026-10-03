"""Step 8 end-to-end test against a deployed service. Prints the JSON at each step, then trashes the test folder.

Usage:  APP_API_KEY=... python scripts/e2e_check.py https://<cloud-run-url> [token.json]
"""
import json
import os
import sys

import requests

base = sys.argv[1].rstrip("/")
token_path = sys.argv[2] if len(sys.argv) > 2 else "token.json"
H = {"X-Api-Key": os.environ["APP_API_KEY"]}


def call(method, path, **kw):
    resp = requests.request(method, base + path, headers=H, timeout=120, **kw)
    print(f"\n== {method} {path} -> {resp.status_code}")
    try:
        print(json.dumps(resp.json(), indent=2)[:4000])
    except ValueError:
        print(resp.text[:1000])
    resp.raise_for_status()
    return resp.json()


def section(key, title, text):
    return {"key": key, "title": title,
            "versions": [{"model": "claude", "at": "2026-10-03", "text": text}],
            "counsel": [{"model": "gemini", "at": "2026-10-03", "target": "original", "text": "Counsel note"}]}


folder = call("POST", "/api/roleintel/folder", json={
    "folderName": "TEST.Sr Counsel.2026-10-03",
    "subfolders": ["Interview Prep", "Resume", "Role Intelligence"]})
again = call("POST", "/api/roleintel/folder", json={"folderName": "TEST.Sr Counsel.2026-10-03"})
assert again["folderId"] == folder["folderId"] and again["existed"], "folder call is not idempotent"

created = call("POST", "/api/roleintel/doc/create", json={
    "folderId": folder["subfolders"]["Role Intelligence"]["id"], "title": "TEST Role Intel",
    "sections": [section("a", "Company Brief", "Line one\nLine two"), section("b", "Questions", "Q1")]})
call("GET", f"/api/roleintel/doc?docId={created['docId']}")
call("POST", "/api/roleintel/doc/write", json={
    "docId": created["docId"], "sections": [section("b", "Questions", "Q1 revised")]})
final = call("GET", f"/api/roleintel/doc?docId={created['docId']}")
assert final["sections"][1]["versions"][0]["text"] == "Q1 revised"
assert final["sections"][0]["versions"][0]["text"] == "Line one\nLine two", "untouched section changed"

# Smoke: existing endpoints still respond.
for path in ("/api/jobs",):
    call("GET", path)

from google.oauth2.credentials import Credentials  # noqa: E402
from googleapiclient.discovery import build  # noqa: E402

drive = build("drive", "v3", credentials=Credentials.from_authorized_user_file(token_path), cache_discovery=False)
drive.files().update(fileId=folder["folderId"], body={"trashed": True}, supportsAllDrives=True).execute()
print("\nTest folder moved to trash:", folder["folderId"])
print("Remember to smoke-test /api/sheet with a real spreadsheet + tab.")
