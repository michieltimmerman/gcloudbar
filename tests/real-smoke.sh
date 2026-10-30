#!/usr/bin/env bash
# Smoke test against the real gcloud and the real login, changing nothing:
#   - its own state file with auto-renew off, so no browser ever opens;
#   - a GUI-like bare environment, so gcloud/Python discovery is exercised;
#   - a before/after fingerprint of the gcloud config dir: content hashes of the
#     configuration files, and only mtime + size of the credential files, which
#     are never opened.
# The probe runs as you, exactly as the app does. Pass a service account to route
# it through impersonation instead (e.g. when an AI agent that must only act as
# its own SA runs this); that path may be answered from gcloud's token cache.
# Usage: tests/real-smoke.sh [service-account]
set -uo pipefail

SA=${1:-}
APP_BIN="${APP_BIN:-$HOME/Applications/GcloudBar.app/Contents/MacOS/GcloudBar}"
T=$(mktemp -d)
G="${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}"

fingerprint() {
    echo "active_config $(cat "$G/active_config")"
    for f in "$G"/configurations/config_*; do
        echo "config $(basename "$f") $(shasum < "$f" | cut -c1-12)"
    done
    for f in application_default_credentials.json credentials.db access_tokens.db; do
        echo "file $f $(stat -f 'mtime=%Sm size=%z' -t '%T' "$G/$f" 2> /dev/null || echo missing)"
    done
}

before=$(fingerprint)
printf '{"autoLogin": false, "notify": false}' > "$T/state.json"
env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" SHELL=/bin/zsh TMPDIR="${TMPDIR:-/tmp}" \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin ${CLOUDSDK_CONFIG:+CLOUDSDK_CONFIG="$CLOUDSDK_CONFIG"} \
    GCLOUDBAR_STATE="$T/state.json" GCLOUDBAR_PROBE_SA="$SA" GCLOUDBAR_DEBUG=1 GCLOUDBAR_NO_BANNERS=1 \
    "$APP_BIN" 2> "$T/app.log" &
PID=$!
for _ in $(seq 1 120); do
    grep -q "probe:" "$T/app.log" && break
    sleep 0.5
done
sleep 2
kill "$PID" 2> /dev/null
wait "$PID" 2> /dev/null
after=$(fingerprint)

echo "=== app log"
cat "$T/app.log"
echo "=== state.json"
cat "$T/state.json"
echo
echo "=== $G fingerprint diff (before → after)"
diff <(echo "$before") <(echo "$after") && echo "no changes"

# access_tokens.db is the token cache: the probe may legitimately write to it.
changed=$(diff <(echo "$before") <(echo "$after") | grep '^>' | grep -v 'access_tokens.db')
probe=$(grep -o 'probe: .*' "$T/app.log" | tail -1)
fail=0
echo "=== verdict"
case "$probe" in
"probe: valid" | "probe: reauth" | "probe: revoked") echo "ok    the probe got a real answer from Google ($probe)" ;;
*) echo "FAIL  the probe got no real answer (${probe:-no probe ran})"; fail=1 ;;
esac
if [ -z "$changed" ]; then
    echo "ok    gcloud configs, active config, ADC and credentials.db untouched"
else
    echo "FAIL  changed: $changed"
    fail=1
fi
rm -rf "$T"
exit "$fail"
