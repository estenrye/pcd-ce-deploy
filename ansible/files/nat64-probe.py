#!/usr/bin/env python3
"""Probe the NAT64/DNS64 appliance (nat64-01) end to end and report to Healthchecks.

Installed by provision-healthchecks.yml as /usr/local/sbin/nat64-probe and run every 5
minutes by nat64-probe.timer. The appliance runs two independent translators (tayga for
the well-known prefix 64:ff9b::/96, tayga-priv for a private prefix) plus the DNS64
resolver (unbound). tayga failed silently once (2026-11-13, an init-script race after
unattended-upgrades) and took all IPv4-only egress down for hours, so each piece is
probed on its own and reported on its own Healthchecks check:

  nat64-wkp      DNS64: the resolver answers AAAA for an IPv4-only name; translation: a TLS
                 handshake to 64:ff9b::<IPv4 of that name> on 443 completes. The address is
                 built here from the A record, so it tests tayga, not just the resolver.
  nat64-private  The resolver returns the private-prefix address for the private host and a
                 TLS handshake to it on 443 completes (tayga-priv).

Environment (EnvironmentFile=/opt/healthchecks/nat64-probe.env):
  PING_URL_WKP, PING_URL_PRIVATE  Healthchecks ping URLs (success, or /fail on error)
  RESOLVER          default fd97:45c2:b3a1:64::64
  WKP_NAME          default github.com (must have an A record)
  PRIVATE_NAME      default pcd.rye.ninja
  PRIVATE_PREFIX    default fd97:45c2:b3a1:64:65::/96
"""

import ipaddress
import os
import random
import socket
import ssl
import struct
import sys
import time
import urllib.error
import urllib.request

RESOLVER = os.environ.get("RESOLVER", "fd97:45c2:b3a1:64::64")
WKP_NAME = os.environ.get("WKP_NAME", "github.com")
PRIVATE_NAME = os.environ.get("PRIVATE_NAME", "pcd.rye.ninja")
PRIVATE_PREFIX = ipaddress.ip_network(os.environ.get("PRIVATE_PREFIX", "fd97:45c2:b3a1:64:65::/96"))
WKP = ipaddress.ip_network("64:ff9b::/96")
ATTEMPTS = 2

A, AAAA = 1, 28


def query(name, qtype):
    """Minimal DNS lookup over UDP against RESOLVER; returns the list of answer addresses."""
    qid = random.randrange(65536)
    msg = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0)
    msg += b"".join(bytes([len(p)]) + p.encode() for p in name.rstrip(".").split(".")) + b"\0"
    msg += struct.pack(">HH", qtype, 1)
    with socket.socket(socket.AF_INET6, socket.SOCK_DGRAM) as s:
        s.settimeout(5)
        s.sendto(msg, (RESOLVER, 53))
        data, _ = s.recvfrom(4096)
    rid, flags, qd, an, _, _ = struct.unpack(">HHHHHH", data[:12])
    if rid != qid or flags & 0xF:
        raise OSError(f"DNS rcode {flags & 0xF} for {name}")
    pos = 12
    for _ in range(qd):  # skip the question
        while data[pos]:
            pos += data[pos] + 1
        pos += 5
    out = []
    for _ in range(an):
        if data[pos] & 0xC0 == 0xC0:
            pos += 2
        else:
            while data[pos]:
                pos += data[pos] + 1
            pos += 1
        rtype, _, _, rdlen = struct.unpack(">HHIH", data[pos:pos + 10])
        pos += 10
        rdata = data[pos:pos + rdlen]
        pos += rdlen
        if rtype == A and qtype == A:
            out.append(ipaddress.IPv4Address(rdata))
        elif rtype == AAAA and qtype == AAAA:
            out.append(ipaddress.IPv6Address(rdata))
    return out


def tls_handshake(addr, sni):
    """Complete a TLS handshake to [addr]:443; the certificate is not verified (reachability only)."""
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    with socket.create_connection((str(addr), 443), timeout=10) as raw:
        with ctx.wrap_socket(raw, server_hostname=sni) as tls:
            return tls.version()


def probe_wkp():
    answers = query(WKP_NAME, AAAA)
    if not answers:
        raise OSError(f"resolver {RESOLVER} returned no AAAA for {WKP_NAME}")
    v4 = query(WKP_NAME, A)
    if not v4:
        raise OSError(f"resolver returned no A record for {WKP_NAME}")
    target = ipaddress.IPv6Address(int(WKP.network_address) | int(v4[0]))
    version = tls_handshake(target, WKP_NAME)
    return f"{WKP_NAME} AAAA {answers[0]}, TLS to {target} ok ({version})"


def probe_private():
    answers = query(PRIVATE_NAME, AAAA)
    inside = [a for a in answers if a in PRIVATE_PREFIX]
    if not inside:
        raise OSError(f"{PRIVATE_NAME} AAAA {[str(a) for a in answers]} not in {PRIVATE_PREFIX}")
    version = tls_handshake(inside[0], PRIVATE_NAME)
    return f"{PRIVATE_NAME} AAAA {inside[0]}, TLS ok ({version})"


def run(func):
    """Return (ok, message). Retries once so a single dropped packet is not an alert."""
    last = "no attempt"
    for attempt in range(ATTEMPTS):
        try:
            return True, func()
        except (OSError, ssl.SSLError, struct.error, IndexError) as exc:
            last = f"{type(exc).__name__}: {exc}"
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
    status = 0
    for label, func, env in (
        ("wkp", probe_wkp, "PING_URL_WKP"),
        ("private", probe_private, "PING_URL_PRIVATE"),
    ):
        ok, message = run(func)
        print(f"{'OK' if ok else 'PROBLEM'} {label}: {message}")
        url = os.environ[env]
        if not ping(url if ok else url + "/fail", message):
            status = 1
    return status


if __name__ == "__main__":
    sys.exit(main())
