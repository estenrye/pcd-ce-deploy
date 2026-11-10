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

# The etcd snapshot CronJob runs every 6h; alert if nothing for 6h + 2h grace.
check = Check.objects.filter(project=project, slug="etcd-snapshot-core-infra").first()
if check is None:
    check = Check(project=project)
check.name = "etcd-snapshot core-infra"
check.slug = "etcd-snapshot-core-infra"
check.kind = "simple"
check.timeout = timedelta(hours=6)
check.grace = timedelta(hours=2)
check.tags = "core-infra etcd backup"
check.desc = "Pinged by the etcd-snapshot CronJob after a successful upload to R2."
check.save()
channel.checks.add(check)

print("OK check_code=%s" % check.code)
