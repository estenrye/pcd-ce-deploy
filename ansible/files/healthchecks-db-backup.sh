#!/usr/bin/env bash
# Daily encrypted backup of the Healthchecks SQLite database to Cloudflare R2.
# Installed by ansible/provision-healthchecks.yml as
# /usr/local/sbin/healthchecks-db-backup and run by healthchecks-db-backup.timer.
#
# Environment (EnvironmentFile=/opt/healthchecks/backup.env, mode 0600):
#   RCLONE_CONFIG_R2_*  rclone remote "r2" (S3 / Cloudflare, bucket-scoped token)
#   R2_BUCKET           bucket name
#   AGE_RECIPIENT       age PUBLIC key; the private key is NOT on this host
#   PING_URL            Healthchecks check for this job (pinged on success, /fail on error)
#
# rclone runs with --network host: the VM is IPv6-only, and a container on the
# default bridge has no IPv6 route (uploads hang).
#
# Steps: consistent copy with SQLite's online backup API (safe while the app
# runs) inside the app container -> integrity check -> gzip -> age encrypt ->
# upload -> prune objects older than RETENTION -> ping.
set -euo pipefail

DATA_DIR=/opt/healthchecks/data
RETENTION="${RETENTION:-30d}"
RCLONE_IMAGE="rclone/rclone@sha256:74c51b8817e5431bd6d7ed27cb2a50d8ee78d77f6807b72a41ef6f898845942b"
ENV_FILE=/opt/healthchecks/backup.env

TMP="$(mktemp -d /opt/healthchecks/backup-tmp.XXXXXX)"
ok=0
cleanup() {
  rm -rf "${TMP}"
  rm -f "${DATA_DIR}/backup.sqlite"   # plaintext copy: never leave it behind
  if [ "${ok}" != 1 ]; then
    curl -fsS -m 10 --retry 3 -o /dev/null "${PING_URL}/fail" || true
  fi
}
trap cleanup EXIT
trap 'exit 143' INT TERM   # run cleanup (and /fail) when stopped

# 1. Consistent copy + integrity check, inside the app container.
docker exec -i healthchecks python - <<'PY'
import sqlite3
src = sqlite3.connect("file:/data/hc.sqlite?mode=ro", uri=True)
dst = sqlite3.connect("/data/backup.sqlite")
src.backup(dst)
result = dst.execute("PRAGMA integrity_check").fetchone()[0]
dst.close()
src.close()
assert result == "ok", result
PY

# 2. Compress and encrypt (public key only).
NAME="healthchecks-db-$(date -u +%Y%m%dT%H%M%SZ).sqlite.gz.age"
gzip -c "${DATA_DIR}/backup.sqlite" | age -r "${AGE_RECIPIENT}" -o "${TMP}/${NAME}"
SIZE="$(wc -c < "${TMP}/${NAME}")"
[ "${SIZE}" -gt 1000 ] || { echo "backup too small (${SIZE} bytes)" >&2; exit 1; }

# 3. Upload and prune. rclone reads its remote from RCLONE_CONFIG_R2_* env vars.
docker run --rm --network host --env-file "${ENV_FILE}" -v "${TMP}:/in:ro" "${RCLONE_IMAGE}" \
  copyto "/in/${NAME}" "r2:${R2_BUCKET}/${NAME}" --checksum
docker run --rm --network host --env-file "${ENV_FILE}" "${RCLONE_IMAGE}" \
  delete "r2:${R2_BUCKET}" --min-age "${RETENTION}" --include 'healthchecks-db-*.sqlite.gz.age'

echo "uploaded ${NAME} (${SIZE} bytes)"
ok=1
curl -fsS -m 10 --retry 3 -o /dev/null "${PING_URL}"
