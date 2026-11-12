#!/usr/bin/env python3
"""Set the owner and group of one path (not recursive) through the TrueNAS API.

A new dataset's root is owned by root, and nothing in the provider sets the
owner. filesystem.chown is a job, so this starts it and waits for the result.
Environment: TRUENAS_URL, TRUENAS_API_KEY, CHOWN_PATH, CHOWN_UID, CHOWN_GID.
The API key goes to curl on stdin so it never appears in the process list.
"""
import json
import os
import subprocess
import sys
import time

url = os.environ["TRUENAS_URL"] + "/api/v2.0"
key = os.environ["TRUENAS_API_KEY"]
path = os.environ["CHOWN_PATH"]
uid = int(os.environ["CHOWN_UID"])
gid = int(os.environ["CHOWN_GID"])


def api(method, endpoint, body=None):
    args = ["curl", "--fail-with-body", "--silent", "--show-error", "--max-time", "120",
            "--config", "-", "-X", method, "-H", "Content-Type: application/json"]
    if body is not None:
        args += ["--data", json.dumps(body)]
    cfg = f'header = "Authorization: Bearer {key}"\n'
    out = subprocess.run(args + [url + endpoint], input=cfg.encode(), capture_output=True)
    if out.returncode:
        sys.exit(f"{method} {endpoint}: {out.stdout.decode()}{out.stderr.decode()}")
    return json.loads(out.stdout or "null")


job = api("POST", "/filesystem/chown",
          {"path": path, "uid": uid, "gid": gid, "options": {"recursive": False}})
for _ in range(60):
    state = api("GET", f"/core/get_jobs?id={job}")[0]
    if state["state"] == "SUCCESS":
        print(f"{path}: owner set to {uid}:{gid}")
        sys.exit(0)
    if state["state"] in ("FAILED", "ABORTED"):
        sys.exit(f"{path}: chown job {state['state']}: {state.get('error')}")
    time.sleep(2)
sys.exit(f"{path}: chown job {job} did not finish in 120s")
