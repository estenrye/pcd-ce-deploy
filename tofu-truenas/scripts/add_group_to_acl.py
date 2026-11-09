#!/usr/bin/env python3
"""Give a group full control over a dataset tree, keeping its existing ACL.

Reads the NFSv4 ACL at ACL_PATH, appends a GROUP entry for GROUP_GID with
FULL_CONTROL (inheriting) unless one is already present, and applies the
result recursively across child datasets without touching ownership. The
filesystem.add_to_acl call is not exposed over REST on TrueNAS 25.10, hence
getacl + setacl. Environment: TRUENAS_URL, TRUENAS_API_KEY, ACL_PATH,
GROUP_GID. Set DRY_RUN=1 to print the ACL that would be applied instead.
The API key goes to curl on stdin so it never appears in the process list.
"""
import json
import os
import subprocess
import sys
import time

url = os.environ["TRUENAS_URL"] + "/api/v2.0"
key = os.environ["TRUENAS_API_KEY"]
path = os.environ["ACL_PATH"]
gid = int(os.environ["GROUP_GID"])


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


acl = api("POST", "/filesystem/getacl", {"path": path})
if acl["acltype"] != "NFS4":
    sys.exit(f"{path}: expected an NFS4 ACL, found {acl['acltype']}")

entries = acl["acl"]
if any(e["tag"] == "GROUP" and e.get("id") == gid and e["perms"].get("BASIC") == "FULL_CONTROL"
       for e in entries):
    print(f"{path}: GROUP {gid} already has FULL_CONTROL, nothing to do")
    sys.exit(0)

entries = [e for e in entries if not (e["tag"] == "GROUP" and e.get("id") == gid)]
for e in entries:
    # Some roots report INHERITED on entries that are really explicit; it is
    # a read-only marker, so don't send it back.
    if "INHERITED" in e["flags"]:
        e["flags"]["INHERITED"] = False
entries.append({"tag": "GROUP", "id": gid, "type": "ALLOW",
                "perms": {"BASIC": "FULL_CONTROL"}, "flags": {"BASIC": "INHERIT"}})

if os.environ.get("DRY_RUN"):
    print(path, json.dumps([(e["tag"], e.get("id"), e["perms"], e["flags"]) for e in entries]))
    sys.exit(0)

request = {
    "path": path, "dacl": entries,
    "options": {"recursive": True, "traverse": True, "validate_effective_acl": False},
}
# getacl reports nfs41_flags as null on some datasets, which setacl rejects.
if acl.get("nfs41_flags"):
    request["nfs41_flags"] = acl["nfs41_flags"]
job = api("POST", "/filesystem/setacl", request)
for _ in range(360):
    state = api("GET", f"/core/get_jobs?id={job}")[0]
    if state["state"] in ("SUCCESS", "FAILED", "ABORTED"):
        if state["state"] != "SUCCESS":
            sys.exit(f"{path}: setacl {state['state']}: {state.get('error')}")
        print(f"{path}: GROUP {gid} granted FULL_CONTROL ({state['state']})")
        sys.exit(0)
    time.sleep(5)
sys.exit(f"{path}: timed out waiting for setacl job {job}")
