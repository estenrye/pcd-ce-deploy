#!/usr/bin/env python3
"""Set one Scan to Network Folder entry on an HP LaserJet MFP and test it.

Everything comes from the environment so the password never appears in the
process list: PRINTER_HOST, ENTRY_NUM, DISPLAY_NAME, FOLDER_PATH, SCAN_USER,
SCAN_PASS. The settings the form already holds (file type, paper size, scan
quality, colour, file prefix) are read back and resubmitted unchanged. Set
DRY_RUN=1 to fetch the form and print what would be posted, or TEST_ONLY=1
to skip saving and only run the entry's connection test (then only
PRINTER_HOST and ENTRY_NUM are needed).

curl does the HTTP: the printer's TLS stack is too old for Python's ssl
defaults, and its certificate is self-signed, hence -k.
"""
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.parse

host = os.environ["PRINTER_HOST"]

# The printer's web server copes badly with parallel requests and connection
# tests, and OpenTofu runs one script per entry at once, so take a lock and
# let the runs go one at a time.
lock = os.path.join(tempfile.gettempdir(), "hp-printer-config.lock")
for _ in range(240):
    try:
        os.mkdir(lock)
        break
    except FileExistsError:
        try:
            if time.time() - os.path.getmtime(lock) > 600:  # left by a crashed run
                os.rmdir(lock)
                continue
        except FileNotFoundError:
            continue
        time.sleep(2)
else:
    sys.exit("timed out waiting for another printer update to finish")
import atexit
atexit.register(lambda: os.path.isdir(lock) and os.rmdir(lock))
entry = os.environ["ENTRY_NUM"]
base = f"https://{host}/hp/device/"


def curl(*args, stdin=None):
    # The printer's web server sometimes drops a connection (curl exit 52,
    # 56, ...) while busy, so retry a few times before giving up.
    for attempt in range(1, 6):
        try:
            return subprocess.run(
                ["curl", "-sk", "-m", "60", *args], input=stdin, capture_output=True, check=True
            ).stdout.decode("utf-8", "replace")
        except subprocess.CalledProcessError as e:
            if attempt == 5:
                raise
            print(f"curl exit {e.returncode}, retrying ({attempt}/5)", file=sys.stderr)
            time.sleep(5 * attempt)


if not os.environ.get("TEST_ONLY"):
    page = curl(base + f"set_config_folderAddNew.html?tab=Scan&menu=ScantoCfg?entryNum={entry}")
    form = page[page.index('ACTION="/hp/device/set_config_folderAddNew.html/config"'):]

    data = {}
    for m in re.finditer(r"<INPUT[^>]*>", form, re.I):
        nm = re.search(r'name="([^"]+)"', m.group(0))
        ty = re.search(r'type="?([^" >]+)', m.group(0), re.I)
        if not nm or (ty and ty.group(1).lower() in ("submit", "button")):
            continue
        v = re.search(r'VALUE="([^"]*)"', m.group(0), re.I)
        data[nm.group(1)] = v.group(1) if v else ""
    for sel in re.finditer(r'<SELECT[^>]*name="([^"]+)"[^>]*>(.*?)</SELECT>', form, re.I | re.S):
        chosen = re.search(r'<OPTION value="([^"]+)"\s+SELECTED', sel.group(2), re.I)
        first = re.search(r'<OPTION value="([^"]+)"', sel.group(2), re.I)
        data[sel.group(1)] = (chosen or first).group(1)

    data.update(
        displayName=os.environ["DISPLAY_NAME"],
        networkFolderPath=os.environ["FOLDER_PATH"],
        UserName=os.environ["SCAN_USER"],
        PassWord=os.environ["SCAN_PASS"],
        folderPin="",
        pinConfirm="",
        Save_button="Save Only",
    )

    if os.environ.get("DRY_RUN"):
        print({k: "<redacted>" if k == "PassWord" else v[:60] for k, v in data.items()})
        sys.exit(0)

    # The body goes to curl on stdin so the password is not in the process list.
    curl("-o", "/dev/null", "-X", "POST", "--data-binary", "@-",
         base + "set_config_folderAddNew.html/config",
         stdin=urllib.parse.urlencode(data).encode())

# Fetching the status page starts the test; poll it until it stops "testing".
# The first read can still show the previous result, and a test occasionally
# fails transiently, so allow a few attempts.
status_url = base + f"info_ScantoFolder_testStatus.html?tab=Scan&menu=ScantoCfg?entryNum={entry}"
result = None
for attempt in range(1, 4):
    curl("-o", "/dev/null", status_url)
    for _ in range(12):
        time.sleep(5)
        status = curl(status_url)
        st = re.search(r'id="testStatus"[^>]*VALUE="([^"]*)"', status)
        msg = re.search(r'id="testMsg"[^>]*VALUE="([^"]*)"', status)
        if st and st.group(1) != "testing":
            result = (st.group(1), msg.group(1) if msg else "")
            break
    if result and result[0] == "pass":
        break
    time.sleep(10)
if result is None:
    sys.exit(f"entry {entry}: timed out waiting for the test")
print(f"entry {entry}: {result[0]} - {result[1]} (attempt {attempt})")
sys.exit(0 if result[0] == "pass" else 1)
