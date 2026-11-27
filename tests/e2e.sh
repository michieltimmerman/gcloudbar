#!/usr/bin/env bash
# End-to-end tests: the real GcloudBar binary (menu bar item and all) against
# tests/fake-gcloud, with every interval 120x faster (10-minute probes take 5s,
# the 5-minute login timeout 2.5s). Each scenario gets its own CLOUDSDK_CONFIG and
# state file; nothing touches your gcloud config or the real state. A setup where
# an AI agent's gcloud impersonates a service account is simulated with
# CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT in the app's environment.
#
# Usage: tests/e2e.sh   (after packaging/build.sh; `mise run test` does both)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_BIN="${APP_BIN:-$HOME/Applications/GcloudBar.app/Contents/MacOS/GcloudBar}"
REAL_CONFIG="${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}"
AGENT_SA="robot-agent@example-project.iam.gserviceaccount.com"
ACCT="test@example.com"
PASS=0
FAIL=0
ALL=$(mktemp -d)
: > "$ALL/calls.log"
: > "$ALL/env.log"

ok() { echo "  ok    $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }
expect() { local desc=$1; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }
not() { ! "$@"; }
# eventually <seconds> <desc> <cmd...>: poll until cmd succeeds. The cmd is re-run
# each poll, so it must be a function, not a "$(...)" baked in at call time.
eventually() {
    local secs=$1 desc=$2
    local end=$((SECONDS + secs))
    shift 2
    while ((SECONDS < end)); do
        if "$@"; then ok "$desc"; return 0; fi
        sleep 0.25
    done
    bad "$desc (not within ${secs}s)"
    return 1
}

calls() { local n; n=$(grep -c -- "$1" "$T/calls.log" 2>/dev/null); echo "${n:-0}"; }
called() { grep -q -- "$1" "$T/calls.log" 2>/dev/null; }
notified() { grep -q -- "notify: $1" "$T/app.log" 2>/dev/null; }
logged() { grep -q -- "$1" "$T/app.log" 2>/dev/null; }
st() {
    python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2]); print("" if v is None else v)' \
        "$T/state.json" "$1" 2>/dev/null
}
state_has() { test -n "$(st "$1")"; }
test_last_login_is() { test "$(st lastLogin)" = "$1"; }
calls_at_least() { test "$(calls "$1")" -ge "$2"; }
between() { python3 -c 'import sys; v=sys.argv[1]; sys.exit(0 if v and float(sys.argv[2]) < float(v) < float(sys.argv[3]) else 1)' "$@"; }
no_stray_gcloud() { ! pgrep -f "sleep 599" >/dev/null; }

scenario() { # scenario <title> <state.json fixture>
    echo "• $1"
    T=$(mktemp -d)
    mkdir -p "$T/cfg/logs"
    echo "$ACCT" > "$T/account"
    echo valid > "$T/probe"
    echo ok > "$T/login"
    : > "$T/calls.log"
    : > "$T/env.log"
    printf '%s' "$2" > "$T/state.json"
}

# plant_login <seconds ago>: a completed terminal `gcloud auth login`, logged the way gcloud does.
plant_login() { # plant_login <seconds ago> [account]
    local f acct="${2:-$ACCT}"
    f="$T/cfg/logs/$(date -v-"$1"S +%Y.%m.%d)/$(date -v-"$1"S +%H.%M.%S).000001.log"
    mkdir -p "$(dirname "$f")"
    printf '%s\n' "2026-01-01 00:00:00,000 DEBUG    root   Running [gcloud.auth.login] with arguments: [ACCOUNT: \"$acct\"]" \
        "2026-01-01 00:00:05,000 INFO     ___FILE_ONLY___ You are now logged in as [$acct]." > "$f"
    touch -t "$(date -v-"$1"S +%Y%m%d%H%M.%S)" "$f"
    PLANTED=$(date -u -v-"$1"S +%Y-%m-%dT%H:%M:%SZ)
}

# plant_use <command> [args]: another tool's gcloud run, as its log appears.
plant_use() {
    local f
    f="$T/cfg/logs/$(date +%Y.%m.%d)/$(date +%H.%M.%S).$RANDOM.log"
    mkdir -p "$(dirname "$f")"
    echo "$(date '+%F %T'),000 DEBUG    root   Running [gcloud.$1] with arguments: [${2:-}]" > "$f"
}
probes() { calls "print-access-token"; }
probes_above() { test "$(probes)" -gt "$1"; }
notes() { local n; n=$(grep -c -- "notify: $1" "$T/app.log" 2>/dev/null); echo "${n:-0}"; }
notes_above() { test "$(notes "$1")" -gt "$2"; }

# exec: `start` backgrounds this function, so without it $PID would be a subshell
# and `kill $PID` would leave the app running.
run_app() {
    exec env -i HOME="$HOME" USER="$USER" TMPDIR="${TMPDIR:-/tmp}" PATH=/usr/bin:/bin \
        GCLOUDBAR_GCLOUD="${GCLOUD:-$HERE/fake-gcloud}" CLOUDSDK_PYTHON="${PY:-/usr/bin/true}" \
        CLOUDSDK_CONFIG="$T/cfg" CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT="$AGENT_SA" \
        GCLOUDBAR_STATE="$T/state.json" GCLOUDBAR_TIME_SCALE=120 \
        GCLOUDBAR_NO_BANNERS=1 GCLOUDBAR_DEBUG=1 GCLOUDBAR_TEST_INBOX="$T/inbox" FAKE_DIR="$T" \
        GCLOUDBAR_LOGIN_BROWSER="${LOGIN_BROWSER:-$PRESENT_BROWSER}" GCLOUDBAR_OPEN_DRY_RUN=1 \
        GCLOUDBAR_UPDATE_URL="${UPDATE_URL:-file://$T/no-such-release.json}" \
        "$APP_BIN" "$@"
}
# The login-browser logic needs an app that is installed everywhere; Safari is.
# The fake gcloud never opens $BROWSER, so no browser window appears.
PRESENT_BROWSER="com.apple.Safari"
login_browser_is() { grep -q "^browser=$1 :: auth $2" "$T/browser.log" 2> /dev/null; }
start() { run_app "$@" 2> "$T/app.log" & PID=$!; }

# make_fake_sdk <dir>: a Google Cloud SDK tree holding exactly the strings the
# compatibility check looks for (Sources/GcloudBar/Compat.swift), with
# tests/fake-gcloud as bin/gcloud.
make_fake_sdk() {
    local s=$1
    mkdir -p "$s/bin" "$s/lib/googlecloudsdk/core/credentials" "$s/lib/googlecloudsdk/command_lib/auth" \
        "$s/lib/googlecloudsdk/calliope" "$s/lib/surface/config" "$s/lib/surface/auth"
    { cat "$HERE/fake-gcloud"; echo '# exec "$CLOUDSDK_PYTHON"'; } > "$s/bin/gcloud"
    chmod +x "$s/bin/gcloud"
    echo "9.9.9" > "$s/VERSION"
    printf '%s\n' "'impersonate_service_account'" "'CLOUDSDK_{section}_{name}'" > "$s/lib/googlecloudsdk/core/properties.py"
    echo "cache_only_rapt" > "$s/lib/googlecloudsdk/command_lib/auth/auth_util.py"
    echo "'--scopes'" > "$s/lib/googlecloudsdk/command_lib/auth/flags.py"
    echo "'--force-auth-refresh'" > "$s/lib/surface/config/config_helper.py"
    printf '%s\n' "'--force'" "'--activate'" "You are now logged in as" > "$s/lib/surface/auth/login.py"
    echo "Running [{}] with arguments" > "$s/lib/googlecloudsdk/calliope/base.py"
    echo "%Y.%m.%d" > "$s/lib/googlecloudsdk/core/log.py"
    printf '%s\n' "Reauthentication failed" "reauth is required" "ReauthFailError" "ReauthRequiredError" \
        "invalid_rapt" "rapt_required" "invalid_grant" > "$s/lib/googlecloudsdk/core/credentials/google_auth_credentials.py"
}
stop() {
    kill "$PID" 2> /dev/null
    wait "$PID" 2> /dev/null
    pkill -f "sleep 599" 2> /dev/null
    cat "$T/calls.log" >> "$ALL/calls.log"
    cat "$T/env.log" >> "$ALL/env.log"
    [ "${KEEP:-}" = 1 ] && echo "    (kept $T)" || rm -rf "$T"
}

# Your own GcloudBar, when running, legitimately writes the real state file, and
# other gcloud tools touch credentials.db; neither belongs in the before/after.
USER_APP_RUNNING=$(pgrep -x GcloudBar > /dev/null && echo 1 || true)
snapshot() {
    # The ADC file by mtime + size only; it is never opened.
    (cd "$REAL_CONFIG" 2> /dev/null && shasum active_config configurations/* 2> /dev/null \
        && stat -f '%N %m %z' application_default_credentials.json 2> /dev/null)
    [ -n "$USER_APP_RUNNING" ] || ls -l "$HOME/Library/Application Support/GcloudBar/state.json" 2> /dev/null
}
REAL_BEFORE=$(snapshot)

scenario "--status: offline self-check" '{}'
plant_login 30
out=$(run_app --status 2>&1)
expect "finds the configured gcloud" grep -q "fake-gcloud" <<< "$out"
expect "finds the last terminal login in gcloud's logs" grep -q "as $ACCT" <<< "$out"
expect "runs nothing but the local \`config get account\`" not grep -qv '^config get account$' "$T/calls.log"
rm -rf "$T"

scenario "skips a Python gcloud can't load with, keeps the one that works" \
    '{"python": "/usr/bin/true"}'
PY=/bad/python start
eventually 5 "rejects the inherited CLOUDSDK_PYTHON" logged "python /bad/python: unusable"
eventually 5 "falls back to the remembered one" logged "python /usr/bin/true: gcloud loads"
eventually 8 "and the probe runs with it" logged "probe: valid"
expect "  … and keeps it for next launch" test "$(st python)" = /usr/bin/true
stop

# Fixtures with "shortestExpired" model a machine that has seen the session policy
# bite before; without it nothing is predicted (see the "no lapse seen" scenario).
scenario "picks up a terminal login, warns before the lapse, learns from it" \
    '{"sessionHours": 0.01, "shortestExpired": 3600, "warnAheadPercent": 50}'
plant_login 10
start
eventually 5 "picks up the terminal login from gcloud's logs" state_has lastLogin
expect "  … with the account from the log" test "$(st account)" = "$ACCT"
eventually 8 "first probe finds the session working" logged "probe: valid"
eventually 15 "warns once the configured share of the session is left" notified "gcloud login lapses in [0-9]"
expect "  … a notification to click for the login" logged "notify: gcloud login lapses in .*Click to log in again.* \\[click: login\\]"
expect "never logs in by itself" test "$(calls 'auth login')" -eq 0
echo reauth > "$T/probe"
echo check > "$T/inbox"
eventually 5 "announces the lapse" notified "gcloud login lapsed — The session has ended.*Click to log in again"
expect "  … still without opening a login" test "$(calls 'auth login')" -eq 0
expect "learns a lower bound on the session length" between "$(st longestValid)" 5 60
expect "learns an upper bound on the session length" between "$(st shortestExpired)" 15 60
stop

scenario "no lapse seen yet (no session policy?): no countdown, no early notices" \
    '{"sessionHours": 0.01}'
plant_login 20
start
eventually 8 "the session is checked" logged "probe: valid"
sleep 15
expect "no heads-up while the session keeps working past the 36s guess" not notified "gcloud login lapses"
echo reauth > "$T/probe"
echo check > "$T/inbox"
eventually 5 "an actual lapse is still announced" notified "gcloud login lapsed"
stop

scenario "heads-up before the lapse: clicking it logs in, the renewal says when it lapses" \
    '{"sessionHours": 0.01, "shortestExpired": 3600, "warnAheadPercent": 50}'
plant_login 20
start
eventually 8 "heads-up inside the warn window" notified "gcloud login lapses in"
sleep 2
expect "no login until the notification is clicked" test "$(calls 'auth login')" -eq 0
echo click > "$T/inbox"
eventually 3 "the click starts gcloud auth login" called "auth login --force --quiet $ACCT --no-activate"
expect "  … while the session still worked" not logged "probe: reauth"
eventually 5 "reports the renewal with the next lapse" notified "gcloud login renewed — Lapses ~[0-9:]* (in 36s)"
expect "  … a notification to click for settings" logged "notify: gcloud login renewed — .*Click for settings. \\[click: settings\\]"
expect "  … with the login page sent to the login browser (\$BROWSER = this app)" login_browser_is "$APP_BIN" "login"
expect "  … and restarts the clock" test "$(st lastLogin)" \> "$PLANTED"
echo click > "$T/inbox"
eventually 3 "clicking the renewal notification opens Settings" logged "settings window: general tab, visible true"
sleep 3
expect "one login, not a loop" test "$(calls 'auth login')" -eq 1
expect "  … without touching ADC (Also renew ADC is off)" test "$(calls 'application-default')" -eq 0
stop

scenario "lapsed session: notifies, clicked login abandoned, click again to retry" \
    '{}'
echo reauth > "$T/probe"
echo hang > "$T/login"
start
eventually 5 "announces the lapse" notified "gcloud login lapsed"
sleep 3
expect "never opens the browser by itself" test "$(calls 'auth login')" -eq 0
echo click > "$T/inbox"
eventually 3 "the click starts the login" called "auth login --force"
eventually 6 "kills the login nobody approved" logged "exit 15 (timed out)"
expect "  … and says so, click to try again" logged "notify: gcloud login not completed — .*Click to try again. \\[click: login\\]"
expect "  … leaving no gcloud running" no_stray_gcloud
sleep 3
expect "no new login by itself" test "$(calls 'auth login')" -eq 1
echo ok > "$T/login"
echo click > "$T/inbox"
eventually 3 "a click retries" calls_at_least "auth login" 2
eventually 5 "the retry succeeds" notified "gcloud login renewed"
stop

scenario "lapse detection when gcloud is used (no schedule)" \
    '{"checkEveryMinutes": 0}'
start
eventually 8 "the launch check runs" logged "probe: valid"
sleep 1
base=$(probes)
plant_use auth.print-access-token "--quiet: true, --scopes: \"https://www.googleapis.com/auth/cloud-platform\""
plant_use config.get "account"
sleep 2
expect "GcloudBar's own probe and local commands don't count as use" test "$(probes)" -eq "$base"
plant_use projects.describe "PROJECT_ID: \"p\""
eventually 3 "another tool's gcloud run triggers a check" probes_above "$base"
expect "  … logged as use" logged "gcloud used: projects.describe"
echo reauth > "$T/probe"
sleep 1
plant_use container.clusters.list ""
eventually 3 "the next use finds the lapse" notified "gcloud login lapsed"
sleep 6
n=$(notes "gcloud login lapsed")
plant_use config.config-helper "--format: \"json\""
eventually 3 "kubectl's config-helper is use; the lapse is announced again while in use" notes_above "gcloud login lapsed" "$n"
sleep 4
expect "no scheduled checks with the schedule off" test "$(grep -c 'probe:' "$T/app.log")" -le 4
expect "never opens the browser by itself" test "$(calls 'auth login')" -eq 0
stop

scenario "lapse detection switches: on use off, on unlock on and off" \
    '{"checkEveryMinutes": 0, "checkOnUse": false}'
start
eventually 8 "the launch check runs" logged "probe: valid"
sleep 1
base=$(probes)
plant_use projects.describe ""
sleep 2
expect "with on-use off, gcloud use triggers nothing" test "$(probes)" -eq "$base"
echo unlock > "$T/inbox"
eventually 3 "unlocking the Mac triggers a check" probes_above "$base"
stop
scenario "lapse detection on unlock switched off" \
    '{"checkEveryMinutes": 0, "checkOnUnlock": false}'
start
eventually 8 "the launch check runs" logged "probe: valid"
sleep 1
base=$(probes)
echo unlock > "$T/inbox"
sleep 2
expect "unlocking the Mac triggers nothing" test "$(probes)" -eq "$base"
stop

scenario "menu: Log in now (clicked right at launch), then Cancel login" '{}'
echo hang > "$T/login"
echo login > "$T/inbox"
start
eventually 5 "Log in now starts gcloud auth login, even before gcloud was located" called "auth login --force"
echo cancel > "$T/inbox"
eventually 3 "Cancel login stops it" logged "-> exit 15$"
sleep 1
expect "  … quietly (no failure notification)" not notified "gcloud login not completed"
expect "  … leaving no gcloud running" no_stray_gcloud
stop

scenario "Also renew ADC: keeps the impersonated service account" \
    '{"renewADC": true}'
echo reauth > "$T/probe"
printf '{"type": "impersonated_service_account", "service_account_impersonation_url": "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/%s:generateAccessToken", "source_credentials": {}, "delegates": []}' \
    "$AGENT_SA" > "$T/cfg/application_default_credentials.json"
start
eventually 5 "announces the lapse" notified "gcloud login lapsed"
echo click > "$T/inbox"
eventually 8 "the click renews the gcloud login first" called "auth login --force"
eventually 5 "then ADC, impersonating the same SA" called "auth application-default login --quiet --impersonate-service-account=$AGENT_SA"
eventually 5 "reports both" logged "notify: gcloud login renewed — .*ADC renewed too"
expect "  … the ADC login page goes to the login browser too" login_browser_is "$APP_BIN" "application-default"
stop

scenario "login browser not installed: gcloud's default browser" '{}'
echo login > "$T/inbox"
LOGIN_BROWSER=invalid.example.no-such-browser start
eventually 5 "Log in now runs gcloud auth login" called "auth login --force"
expect "  … without overriding \$BROWSER" login_browser_is "<unset>" "login"
stop

scenario "Open logins in … switched off: gcloud's default browser" \
    '{"useLoginBrowser": false}'
echo login > "$T/inbox"
start
eventually 5 "Log in now runs gcloud auth login" called "auth login --force"
expect "  … without overriding \$BROWSER" login_browser_is "<unset>" "login"
stop

scenario "update check: a newer release is announced once; clicking opens its page" '{}'
printf '{"tag_name": "v99.0.0", "html_url": "https://github.com/michieltimmerman/gcloudbar/releases/tag/v99.0.0"}' \
    > "$T/release.json"
UPDATE_URL="file://$T/release.json" start
eventually 5 "looks up the latest release" logged "update check: latest 99.0.0"
eventually 2 "  … announces it" notified "GcloudBar 99.0.0 is available — You have .*Click to open the release page. \\[click: update\\]"
expect "  … and remembers it" test "$(st latestVersion)" = "99.0.0"
echo click > "$T/inbox"
eventually 3 "clicking opens the release page" logged "opening https://github.com/michieltimmerman/gcloudbar/releases/tag/v99.0.0"
echo "check updates" > "$T/inbox"
eventually 3 "Check now looks again" bash -c "test \$(grep -c 'update check: latest' '$T/app.log') -ge 2"
expect "  … without announcing the same version twice" test "$(notes 'GcloudBar 99.0.0 is available')" -eq 1
stop

scenario "update check: an older release, a failed check, switched off" '{}'
printf '{"tag_name": "v0.0.1", "html_url": "https://example.invalid/r"}' > "$T/release.json"
UPDATE_URL="file://$T/release.json" start
eventually 5 "an older release" logged "update check: latest 0.0.1"
expect "  … is not announced" not notified "is available"
stop
scenario "update check: no answer" '{}'
start
eventually 5 "a failed check is logged" logged "update check failed"
expect "  … quietly" not notified "is available"
stop
scenario "update check: switched off" '{"checkUpdates": false}'
start
eventually 8 "first probe" logged "probe: valid"
sleep 2
expect "no update check" not logged "update check"
stop

scenario "\$BROWSER hand-off: GcloudBar <url> opens it via LaunchServices" '{}'
url="https://accounts.google.com/o/oauth2/auth?client_id=x&state=y"
out=$(GCLOUDBAR_OPEN_DRY_RUN=1 GCLOUDBAR_LOGIN_BROWSER="$PRESENT_BROWSER" "$APP_BIN" "$url")
expect "in the login browser when installed" test "$out" = "open -b $PRESENT_BROWSER $url"
out=$(GCLOUDBAR_OPEN_DRY_RUN=1 GCLOUDBAR_LOGIN_BROWSER=invalid.example.no-such-browser "$APP_BIN" "$url")
expect "in the default browser otherwise" test "$out" = "open $url"
rm -rf "$T"

scenario "gcloud without the hidden --scopes flag: documented config-helper fallback" \
    '{}'
touch "$T/no_scopes"
start
eventually 8 "falls back to config-helper --force-auth-refresh" called "config config-helper --force-auth-refresh"
eventually 3 "  … which still answers" logged "probe: valid"
echo reauth > "$T/probe"
echo check > "$T/inbox"
eventually 8 "  … and still sees a lapse right away" logged "probe: reauth"
stop

scenario "a reworded lapse is still recognised (OAuth error code)" '{}'
echo reauth_reworded > "$T/probe"
start
eventually 8 "classified as the session lapse, not as revoked" logged "probe: reauth"
stop

scenario "Settings window opens on either tab" '{}'
start
eventually 8 "first probe" logged "probe: valid"
echo settings > "$T/inbox"
eventually 3 "General tab shown" logged "settings window: general tab, visible true"
echo "settings gcloud" > "$T/inbox"
eventually 3 "gcloud tab shown" logged "settings window: gcloud tab, visible true"
stop

scenario "command line: --help and bad values" '{}'
out=$("$APP_BIN" --help)
expect "--help lists the settings" grep -q -- "--warn-ahead PERCENT" <<< "$out"
"$APP_BIN" --warn-ahead 90 > /dev/null 2>&1
expect "a bad value is refused (exit 2)" test $? -eq 2
"$APP_BIN" --no-such-flag > /dev/null 2>&1
expect "an unknown option is refused (exit 2)" test $? -eq 2
rm -rf "$T"

scenario "arguments override settings for one run and are not saved" '{"checkEveryMinutes": 10}'
start --check-every off --check-on-use off --warn-ahead 20
eventually 8 "the launch check runs" logged "probe: valid"
sleep 7
expect "--check-every off: no scheduled check (5s at 120x)" test "$(probes)" -eq 1
plant_use projects.describe ""
sleep 2
expect "--check-on-use off: use triggers nothing" test "$(probes)" -eq 1
expect "  … and the saved settings are untouched" test "$(st checkEveryMinutes)" = "10"
stop

scenario "--compat checks a gcloud install" '{}'
make_fake_sdk "$T/sdk"
out=$("$APP_BIN" --compat "$T/sdk")
rc=$?
expect "a complete install passes (exit 0)" test "$rc" -eq 0
expect "  … all checks listed" grep -q "gcloud 9.9.9: all 13 checks pass" <<< "$out"
# gcloud 591 split properties.py into a properties/ package.
mkdir -p "$T/sdk/lib/googlecloudsdk/core/properties/sections"
echo "'impersonate_service_account'" > "$T/sdk/lib/googlecloudsdk/core/properties/sections/auth.py"
echo "'CLOUDSDK_{section}_{name}'" > "$T/sdk/lib/googlecloudsdk/core/properties/types.py"
rm "$T/sdk/lib/googlecloudsdk/core/properties.py"
expect "  … also in gcloud 591's properties/ layout" bash -c "'$APP_BIN' --compat '$T/sdk' > /dev/null"
sed -i '' '/You are now logged in as/d' "$T/sdk/lib/surface/auth/login.py"
out=$("$APP_BIN" --compat "$T/sdk")
rc=$?
expect "a missing piece fails (exit 1)" test "$rc" -eq 1
expect "  … naming the feature it serves" grep -q "FAIL  terminal logins are spotted in gcloud's logs (success line)" <<< "$out"
printf '%s\n' "invalid_rapt" "invalid_grant" > "$T/sdk/lib/googlecloudsdk/core/credentials/google_auth_credentials.py"
out=$("$APP_BIN" --compat "$T/sdk")
expect "losing some lapse markers is only a warning" grep -q "warn  the session lapse is recognised" <<< "$out"
"$APP_BIN" --compat "$T/no-sdk" > /dev/null 2>&1
expect "no SDK there: exit 2" test $? -eq 2
rm -rf "$T"

scenario "the app checks its gcloud at launch and notifies once" '{}'
make_fake_sdk "$T/sdk"
sed -i '' "/'--activate'/d" "$T/sdk/lib/surface/auth/login.py"
GCLOUD="$T/sdk/bin/gcloud" start
eventually 8 "checks the installed gcloud" logged "compat: gcloud 9.9.9: 1 problem"
eventually 3 "  … notifies" notified "gcloud 9.9.9 changed something GcloudBar relies on"
expect "  … and remembers that version" test "$(st compatNotified)" = "9.9.9"
stop

scenario "revoked credentials count as lapsed" '{}'
echo revoked > "$T/probe"
start
eventually 5 "probe reports revoked" logged "probe: revoked"
eventually 3 "announces it" notified "gcloud login lapsed"
stop

scenario "offline: a failed check never triggers a login" \
    '{"sessionHours": 0.01}'
echo fail > "$T/probe"
start
eventually 5 "probe reports the failure" logged "probe: failed"
sleep 6
expect "no login attempted" test "$(calls 'auth login')" -eq 0
eventually 15 "says so once the checks keep failing" notified "GcloudBar can't check your gcloud login"
stop

scenario "gcloud's Python vanishes while running (mise/pyenv upgrade)" '{}'
printf '#!/bin/sh\n' > "$T/python3" && chmod +x "$T/python3"
PY="$T/python3" start
eventually 8 "first probe works" logged "probe: valid"
rm "$T/python3"
echo check > "$T/inbox"
eventually 8 "the check sees gcloud can't start" logged "probe: broken"
eventually 10 "and looks for gcloud and a Python again" bash -c "test \$(grep -c 'toolchain gcloud=' '$T/app.log') -ge 2"
stop

scenario "no check runs while a login is open" '{}'
echo hang > "$T/login"
start
eventually 8 "first probe" logged "probe: valid"
echo login > "$T/inbox"
eventually 3 "login open" called "auth login --force"
probes_before=$(calls "print-access-token")
echo check > "$T/inbox"
sleep 1.5
expect "Check now during the login runs nothing" test "$(calls 'print-access-token')" -eq "$probes_before"
echo cancel > "$T/inbox"
stop

scenario "another account's login is ignored; switching accounts starts over" \
    '{}'
plant_login 30
OTHER_PLANTED=""
plant_login 5 "other@example.com"
OTHER_PLANTED=$PLANTED
plant_login 30
start
eventually 8 "first probe" logged "probe: valid"
expect "the other account's newer login doesn't count" test "$(st lastLogin)" \< "$OTHER_PLANTED"
expect "  … the checked account stays" test "$(st account)" = "$ACCT"
echo "other@example.com" > "$T/account"
echo check > "$T/inbox"
eventually 8 "after switching, the new account's login counts" test_last_login_is "$OTHER_PLANTED"
expect "  … for the new account" test "$(st account)" = "other@example.com"
stop

scenario "quitting the app stops an open login" '{}'
echo hang > "$T/login"
start
eventually 8 "first probe" logged "probe: valid"
echo login > "$T/inbox"
eventually 3 "login open" called "auth login --force"
kill -TERM "$PID"
wait "$PID" 2> /dev/null
sleep 0.5
expect "gcloud auth login is gone with the app" no_stray_gcloud
stop

echo "• leaves the agent service-account setup alone (all scenarios)"
expect "probes ran" bash -c "grep -q 'auth print-access-token' '$ALL/env.log'"
expect "every probe switched impersonation off for its own call (checks your login, not the agent's cache)" \
    bash -c "! grep -E 'auth print-access-token|config config-helper --force-auth-refresh' '$ALL/env.log' | grep -qv '^impersonate_env= ::'"
expect "the other calls kept the agent impersonation env as-is" \
    bash -c "! grep -vE 'auth print-access-token|config config-helper --force-auth-refresh' '$ALL/env.log' | grep -qv '^impersonate_env=$AGENT_SA ::'"
expect "never --update-adc (it would replace an impersonated ADC)" bash -c "! grep -q -- '--update-adc' '$ALL/calls.log'"
expect "every login used --no-activate (gcloud configuration not rewritten)" \
    bash -c "! grep '^auth login' '$ALL/calls.log' | grep -qv -- '--no-activate'"
expect "only read/login commands: no config set/unset, revoke, activate-service-account" \
    bash -c "! grep -Ev '^(config get account|auth print-access-token --quiet --scopes=|config config-helper --force-auth-refresh |auth login --force --quiet |auth application-default login --quiet)' '$ALL/calls.log' | grep -q ."
expect "real gcloud config (configs, active config, ADC)${USER_APP_RUNNING:+ (state file skipped: your own GcloudBar is running)} and real state file untouched" \
    test "$REAL_BEFORE" = "$(snapshot)"
rm -rf "$ALL"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
