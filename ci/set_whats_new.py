#!/usr/bin/env python3
"""Set a TestFlight build's "What to Test" notes via the App Store Connect API.

Usage: set_whats_new.py <bundle-id> <build-number> <notes-file>
Env:   ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (the .p8 file)

The build shows up in the API a few minutes after upload (while it's still
processing), so this polls for it. The notes can be set before processing
finishes. Requires: pip install pyjwt cryptography
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt

API = "https://api.appstoreconnect.apple.com/v1"
LOCALE = "en-US"
POLL_SECONDS = 30
TIMEOUT_SECONDS = 30 * 60


def token() -> str:
    with open(os.environ["ASC_KEY_PATH"]) as f:
        key = f.read()
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"},
        key,
        algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"},
    )


def call(method: str, path: str, body: dict | None = None) -> dict:
    url = path if path.startswith("http") else API + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token()}")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} {url} failed: {e.code} {e.read().decode(errors='replace')}")


def main() -> None:
    bundle_id, build_number, notes_path = sys.argv[1:4]
    with open(notes_path, encoding="utf-8") as f:
        notes = f.read().strip()
    # App Store Connect rejects emoji (anything outside the Basic
    # Multilingual Plane) in whatsNew; drop them rather than fail.
    stripped = "".join(ch for ch in notes if ord(ch) <= 0xFFFF)
    if stripped != notes:
        print("Note: removed emoji from the notes (App Store Connect doesn't allow them).")
        notes = stripped
    if len(notes) > 4000:
        sys.exit(f"Notes are {len(notes)} characters; TestFlight allows 4000.")

    apps = call("GET", "/apps?" + urllib.parse.urlencode({"filter[bundleId]": bundle_id}))["data"]
    if not apps:
        sys.exit(f"No app with bundle id {bundle_id}")
    app_id = apps[0]["id"]

    query = urllib.parse.urlencode({"filter[app]": app_id, "filter[version]": build_number, "limit": 1})
    deadline = time.time() + TIMEOUT_SECONDS
    while True:
        builds = call("GET", f"/builds?{query}")["data"]
        if builds:
            build_id = builds[0]["id"]
            break
        if time.time() > deadline:
            sys.exit(f"Build {build_number} didn't appear in App Store Connect within {TIMEOUT_SECONDS // 60} minutes.")
        print(f"Waiting for build {build_number} to appear in App Store Connect…", flush=True)
        time.sleep(POLL_SECONDS)

    existing = call("GET", f"/builds/{build_id}/betaBuildLocalizations")["data"]
    match = next((loc for loc in existing if loc["attributes"].get("locale") == LOCALE), None)
    if match:
        call("PATCH", f"/betaBuildLocalizations/{match['id']}", {
            "data": {"type": "betaBuildLocalizations", "id": match["id"], "attributes": {"whatsNew": notes}},
        })
    else:
        call("POST", "/betaBuildLocalizations", {
            "data": {
                "type": "betaBuildLocalizations",
                "attributes": {"locale": LOCALE, "whatsNew": notes},
                "relationships": {"build": {"data": {"type": "builds", "id": build_id}}},
            },
        })
    print(f"Set What to Test ({LOCALE}) on build {build_number}.")


if __name__ == "__main__":
    main()
