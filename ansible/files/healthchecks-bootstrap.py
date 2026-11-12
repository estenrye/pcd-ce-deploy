# First-run setup for self-hosted Healthchecks. Idempotent: safe to re-run.
# Run inside the app container:  ./manage.py shell < healthchecks-bootstrap.py
# Secrets arrive as environment variables (docker exec -e NAME, no value on the
# command line): HC_ADMIN_EMAIL, HC_ADMIN_PASSWORD, HC_DISCORD_WEBHOOK.
import json
import os
from datetime import timedelta

from django.contrib.auth.models import User

from hc.accounts.views import _make_user
from hc.api.models import Channel, Check

email = os.environ["HC_ADMIN_EMAIL"]
password = os.environ["HC_ADMIN_PASSWORD"]
webhook = os.environ["HC_DISCORD_WEBHOOK"]

user = User.objects.filter(email=email).first()
if user is None:
    user = _make_user(email)
    print("created user")
user.is_staff = True
user.is_superuser = True
user.set_password(password)
user.save()

project = user.project_set.first()
project.name = "core-infra"
project.save()

# _make_user adds a sample check; drop it, it would alert about nothing.
Check.objects.filter(project=project, name="My First Check").delete()

# Discord (Slack-compatible endpoint) alert channel.
spec = {
    "method_down": "POST",
    "url_down": webhook,
    "body_down": json.dumps({"text": ":rotating_light: $NAME is $STATUS"}),
    "headers_down": {"Content-Type": "application/json"},
    "method_up": "POST",
    "url_up": webhook,
    "body_up": json.dumps({"text": ":white_check_mark: $NAME is $STATUS"}),
    "headers_up": {"Content-Type": "application/json"},
}
channel = Channel.objects.filter(project=project, kind="webhook").first()
if channel is None:
    channel = Channel(project=project, kind="webhook")
channel.name = "Discord"
channel.value = json.dumps(spec)
channel.save()

# Checks. Each is a dead-man's-switch: the job that owns it pings on success,
# /fail on a detected problem, and silence past period+grace also alerts.
CHECKS = [
    # name, slug, period, grace, tags, description
    (
        "etcd-snapshot core-infra",
        "etcd-snapshot-core-infra",
        timedelta(hours=6),
        timedelta(hours=2),
        "core-infra etcd backup",
        "Pinged by the etcd-snapshot CronJob after a successful upload to R2.",
    ),
    # cnpg-backup-watcher CronJob runs daily at 05:00 UTC, after the
    # 03:15/03:45 UTC ScheduledBackups.
    (
        "cnpg-backup keycloak-db",
        "cnpg-backup-keycloak-db",
        timedelta(days=1),
        timedelta(hours=3),
        "core-infra cnpg backup",
        "Pinged by the cnpg-backup-watcher CronJob when the latest CNPG backup is fresh and WAL archiving is healthy.",
    ),
    (
        "cnpg-backup grafana-db",
        "cnpg-backup-grafana-db",
        timedelta(days=1),
        timedelta(hours=3),
        "core-infra cnpg backup",
        "Pinged by the cnpg-backup-watcher CronJob when the latest CNPG backup is fresh and WAL archiving is healthy.",
    ),
    (
        "cnpg-backup seaweedfs-db",
        "cnpg-backup-seaweedfs-db",
        timedelta(days=1),
        timedelta(hours=3),
        "core-infra cnpg backup",
        "Pinged by the cnpg-backup-watcher CronJob when the latest CNPG backup is fresh and WAL archiving is healthy.",
    ),
    (
        "cnpg-backup gitea-db",
        "cnpg-backup-gitea-db",
        timedelta(days=1),
        timedelta(hours=3),
        "core-infra cnpg backup",
        "Pinged by the cnpg-backup-watcher CronJob when the latest CNPG backup is fresh and WAL archiving is healthy.",
    ),
    # gitea-repos-capacity CronJob (flux-platform-src applications/gitea) runs
    # hourly at :17, pings on success and /fail at 75% or more of the
    # gitea-repos dataset quota (50 GiB).
    (
        "gitea-repos capacity",
        "gitea-repos-capacity",
        timedelta(hours=1),
        timedelta(minutes=30),
        "core-infra gitea",
        "Pinged by the gitea-repos-capacity CronJob while the Gitea repository volume is under 75% full; /fail at or above 75%.",
    ),
    # Same gitea-repos-capacity CronJob, hourly at :17: pings on success while the
    # newest ZFS snapshot of the gitea-repos dataset (read from .zfs/snapshot on
    # the NFS mount) is under 26 hours old; /fail when it is older or missing.
    (
        "gitea-repos snapshots",
        "gitea-repos-snapshots",
        timedelta(hours=1),
        timedelta(minutes=30),
        "core-infra gitea",
        "Pinged by the gitea-repos-capacity CronJob while the newest ZFS snapshot of the Gitea repository dataset is under 26 hours old; /fail when older or missing.",
    ),
    # Daily 02:30 UTC timer on this VM (healthchecks-db-backup.timer). It can
    # only alert while Healthchecks itself is up: it catches a failing backup,
    # not the loss of this VM.
    (
        "healthchecks-db-backup",
        "healthchecks-db-backup",
        timedelta(days=1),
        timedelta(hours=3),
        "healthchecks backup",
        "Pinged by healthchecks-db-backup.service after an encrypted DB backup is uploaded to R2.",
    ),
    # Nightly timer on the KVM host (zfs-replicate-vms.timer, 02:30 UTC +
    # up to 15 min random delay) replicating the vmpool/vms zvols (pcd-ce) to
    # the NAS. Pings /start when it begins, success when every zvol is sent
    # and pruned, /fail on error.
    (
        "zfs-replicate-vms",
        "zfs-replicate-vms",
        timedelta(days=1),
        timedelta(hours=3),
        "kvm backup",
        "Pinged by zfs-replicate-vms.service on mf-ms-a2-01 after the nightly vmpool/vms zvol replication to the NAS completes.",
    ),
]

for name, slug, period, grace, tags, desc in CHECKS:
    check = Check.objects.filter(project=project, slug=slug).first()
    if check is None:
        check = Check(project=project)
    check.name = name
    check.slug = slug
    check.kind = "simple"
    check.timeout = period
    check.grace = grace
    check.tags = tags
    check.desc = desc
    check.save()
    channel.checks.add(check)
    print("CHECK %s %s" % (slug, check.code))

print("OK")
