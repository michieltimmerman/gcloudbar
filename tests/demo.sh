#!/usr/bin/env bash
# Start GcloudBar with demo data, for screenshots: a fake gcloud (tests/fake-gcloud),
# the account demo@example.com, a session that has seen its policy and lapses in
# about 13 hours. Nothing touches your real gcloud or GcloudBar settings.
# Quit your own GcloudBar first if you don't want two icons. Ctrl-C ends the demo.
#
# Usage: tests/demo.sh [extra GcloudBar arguments]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_BIN="${APP_BIN:-$HOME/Applications/GcloudBar.app/Contents/MacOS/GcloudBar}"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/cfg/logs"
echo demo@example.com > "$T/account"
echo valid > "$T/probe"
echo ok > "$T/login"
printf '{"account": "demo@example.com", "autoLogin": true, "notify": true, "lastLogin": "%s", "shortestExpired": 57600, "longestValid": 10800}' \
    "$(date -u -v-3H -v-1M +%Y-%m-%dT%H:%M:%SZ)" > "$T/state.json"

echo "GcloudBar demo running (demo@example.com). Click its menu bar item; Ctrl-C to stop."
env -i HOME="$HOME" USER="$USER" TMPDIR="${TMPDIR:-/tmp}" PATH=/usr/bin:/bin \
    GCLOUDBAR_GCLOUD="$HERE/fake-gcloud" CLOUDSDK_PYTHON=/usr/bin/true CLOUDSDK_CONFIG="$T/cfg" \
    GCLOUDBAR_STATE="$T/state.json" GCLOUDBAR_NO_BANNERS=1 GCLOUDBAR_TEST_INBOX="$T/inbox" FAKE_DIR="$T" \
    "$APP_BIN" "$@"
