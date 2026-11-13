#!/usr/bin/env python3
"""Probe Git SSH on git.rye.ninja from outside the cluster and report to Healthchecks.

Installed by ansible/provision-healthchecks.yml as /usr/local/sbin/gitea-ssh-probe and run
every 5 minutes by gitea-ssh-probe.timer. It opens a TCP connection to HOST:PORT and reads
the SSH identification string (`SSH-2.0-...`), which proves the whole path: security group,
UniFi firewall, Gateway listener, TCPRoute, NetworkPolicy and Gitea's SSH server. It does not
authenticate. The cluster itself cannot run this check (pods cannot reach the Gateway's own
public VIP), which is why it lives on this VM.

Environment (EnvironmentFile=/opt/healthchecks/gitea-ssh-probe.env):
  PING_URL  Healthchecks ping URL for the gitea-ssh check (pinged on success, /fail on error)
  HOST      default git.rye.ninja
  PORT      default 22
"""

import os
import socket
import sys
import time
import urllib.error
import urllib.request

HOST = os.environ.get("HOST", "git.rye.ninja")
PORT = int(os.environ.get("PORT", "22"))
ATTEMPTS = 2


def probe():
    """Return (ok, message). Retries once so a single dropped SYN is not an alert."""
    last = "no attempt"
    for attempt in range(ATTEMPTS):
        try:
            with socket.create_connection((HOST, PORT), timeout=10) as s:
                peer = s.getpeername()[0]
                s.settimeout(10)
                banner = s.recv(255).decode("ascii", "replace").strip()
            if banner.startswith("SSH-2.0-"):
                return True, f"{HOST}:{PORT} ({peer}) {banner}"
            last = f"{HOST}:{PORT} ({peer}) answered but not with an SSH banner: {banner[:60]!r}"
        except (OSError, UnicodeError) as exc:
            last = f"{HOST}:{PORT} {type(exc).__name__}: {exc}"
        if attempt + 1 < ATTEMPTS:
            time.sleep(5)
    return False, last


def ping(url, body):
    last = None
    for _ in range(3):
        try:
            req = urllib.request.Request(url, data=body.encode()[:10000], method="POST")
            with urllib.request.urlopen(req, timeout=15) as resp:
                resp.read()
            return True
        except (urllib.error.URLError, OSError) as exc:
            last = exc
            time.sleep(5)
    print(f"ping failed after retries: {last}", file=sys.stderr)
    return False


def main():
    ok, message = probe()
    print(("OK " if ok else "PROBLEM ") + message)
    url = os.environ["PING_URL"]
    return 0 if ping(url if ok else url + "/fail", message) else 1


if __name__ == "__main__":
    sys.exit(main())
