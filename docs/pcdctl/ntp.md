# pcdctl doesn't recognize systemd-timesyncd as valid NTP

## Summary

`pcdctl prep-node`'s "Enable NTP for time synchronization" pre-requisite
check reports failure (`x`) on a host where `systemd-timesyncd` is actively
running and the clock is confirmed synchronized. The check's own output text
even says the failure `(not mandatory because systemd-timesyncd is
installed)` — but despite that self-declared non-mandatory status, it still
counts as an "optional pre-requisite check failure," which blocks
non-interactive automation unless explicitly skipped.

## Environment

- Host: `pcd-ce-hyp-01` (`fd97:45c2:b3a1:100:e481:3fff:fec5:249f`), a PCD
  hypervisor prepped by
  [ansible/prep-pcd-hypervisor.yml](../../ansible/prep-pcd-hypervisor.yml).
- `pcdctl` version `1.0.320`.
- OS: Ubuntu, time sync provided by `systemd-timesyncd` (the default on this
  image — no `chronyd` or `ntpd` installed).

## Investigation

### 1. `systemd-timesyncd` is genuinely active and synced

```
$ systemctl is-active systemd-timesyncd
active

$ timedatectl show -p NTPSynchronized --value
yes
```

Both the service and the actual sync state are healthy — this isn't a case
of the daemon being installed but not working.

### 2. `pcdctl prep-node` flags it as failed anyway

```
✓ Check if virtualization is enabled
✓ Load the modules needed for Neutron
✓ Add sysctl options
x Enable NTP for time synchronization (not mandatory because systemd-timesyncd is installed)
✓ Start and Enable iscsid service
✓ Install the Router Advertisement Daemon
✓ Adding OpenStack Services FQDN in /etc/hosts

✓ Completed Pre-Requisite Checks successfully
```

The check's own message acknowledges `systemd-timesyncd` is present and
implies that should be sufficient — but it's still marked `x`, not `✓`.
`pcdctl` appears to specifically probe for `chronyd`/`ntpd` (matching the
three services the [PCD prerequisites
docs](https://docs.platform9.com/private-cloud-director/getting-started/pre-requisites)
list — `chronyd`, `ntpd`, or `systemd-timesyncd`), but the prep-node check
implementation doesn't accept the third option the docs themselves name as
valid.

### 3. This isn't just cosmetic — it blocks non-interactive runs

Any `x` result, even one the tool itself labels non-mandatory, makes
`prep-node` treat the overall run as having "optional pre-requisite check
failure(s)." Interactively, this surfaces as a prompt:

```
Optional pre-requisite check(s) failed. Do you want to continue? (y/n)
```

Run without a TTY (e.g. under Ansible via `ansible.builtin.command`), that
prompt blocks on a `stdin` read that never resolves — the process just hangs
indefinitely (confirmed via `/proc/<pid>/fd`, showing `fd 0 -> /dev/pts/1`
with no input ever arriving).

Adding `--no-prompt` (a documented global flag) doesn't auto-accept the
optional-check failure — it fails closed instead:

```
x Optional pre-requisite check(s) failed. Use --skip-checks to skip these checks.
```

(exit code 1). So `--no-prompt` alone converts an infinite hang into a clean
failure, but doesn't make the run succeed.

### 4. The fix: `--skip-ntp`

`pcdctl prep-node --help` exposes both a broad and a targeted flag:

```
-c, --skip-checks   Will skip optional checks if true
-n, --skip-ntp       Will skip ntp installation if true
```

`--skip-checks` would skip *all* optional checks, not just this one.
Since NTP is the only one actually failing here, `--skip-ntp` is the
narrower, more precise fix — it doesn't silently wave off any other
optional check that might start failing for a real reason later.

## Root cause, in one sentence

`pcdctl prep-node`'s NTP check only recognizes `chronyd`/`ntpd`, not
`systemd-timesyncd`, even though systemd-timesyncd is one of the three
NTP services Platform9's own prerequisites documentation lists as
acceptable — and because the check still counts as an unmet "optional"
check even when self-labeled non-mandatory, it silently hangs
non-interactive automation unless `--no-prompt` and `--skip-ntp` are both
passed explicitly.

## Where this is handled in this repo

[ansible/prep-pcd-hypervisor.yml](../../ansible/prep-pcd-hypervisor.yml)
runs `pcdctl prep-node --no-prompt --skip-ntp`, and separately verifies NTP
sync itself (via `timedatectl show -p NTPSynchronized --value`) as its own
explicit pre-flight check earlier in the play — so real NTP failures are
still caught by this playbook, just not by relying on pcdctl's own
(incomplete) check.
