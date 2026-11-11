#!/usr/bin/env python3
"""Set a user's passwordless sudo commands (sudo_commands_nopasswd).

The truenas provider's truenas_user has no sudo_commands_nopasswd, so this
looks the user up by name and PUTs the list through the REST API.
Environment: TRUENAS_URL, TRUENAS_API_KEY, USERNAME, SUDO_COMMANDS (JSON list).
The API key goes to curl on stdin so it never appears in the process list.
"""
import json
import os
import subprocess
import sys

url = os.environ["TRUENAS_URL"] + "/api/v2.0"
key = os.environ["TRUENAS_API_KEY"]
username = os.environ["USERNAME"]
commands = json.loads(os.environ["SUDO_COMMANDS"])


def api(method, endpoint, body=None):
    args = ["curl", "--fail-with-body", "--silent", "--show-error", "--max-time", "60",
            "--config", "-", "-X", method, "-H", "Content-Type: application/json"]
    if body is not None:
        args += ["--data", json.dumps(body)]
    cfg = f'header = "Authorization: Bearer {key}"\n'
    out = subprocess.run(args + [url + endpoint], input=cfg.encode(), capture_output=True)
    if out.returncode:
        sys.exit(f"{method} {endpoint}: {out.stdout.decode()}{out.stderr.decode()}")
    return json.loads(out.stdout or "null")


users = api("GET", f"/user?username={username}")
if len(users) != 1:
    sys.exit(f"expected one user named {username}, found {len(users)}")
user = users[0]

if user["sudo_commands_nopasswd"] == commands:
    print(f"{username}: sudo_commands_nopasswd already set, nothing to do")
    sys.exit(0)

api("PUT", f"/user/id/{user['id']}", {"sudo_commands_nopasswd": commands})
print(f"{username}: set {len(commands)} passwordless sudo commands")
