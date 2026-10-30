# GcloudBar

A macOS menu bar item that keeps your `gcloud` CLI login from lapsing.

Organisations on Google Workspace can turn on **Google Cloud session control**.
It makes gcloud's refresh token stop working a fixed time after your last
interactive login. The admin picks the length; 16 hours is common. After that
every command fails with:

```
Reauthentication failed. cannot prompt during non-interactive execution.
```

The login itself can't be automated, since the browser + 2FA step is the point of
the policy. GcloudBar works out when your session will lapse and opens the login
for you shortly before. All you do is approve it in the browser.

## Requirements

- macOS 14 or later
- Xcode or the Command Line Tools (Swift 5.9+) to build
- The [Google Cloud CLI](https://cloud.google.com/sdk/docs/install). GcloudBar
  looks in these places:
  - `~/google-cloud-sdk`
  - Homebrew, both `/opt/homebrew` and `/usr/local`
  - mise and asdf installs

  Point it elsewhere with `GCLOUDBAR_GCLOUD`.
- A Python ≥ 3.10 that gcloud can load with. Finding it is automatic, see
  [Finding gcloud and Python](#finding-gcloud-and-python).
- Optional: [`terminal-notifier`](https://github.com/julienXX/terminal-notifier)
  (`brew install terminal-notifier`) for proper notifications; without it they
  go through `osascript`.
- Optional: [mise](https://mise.jdx.dev) for the task shortcuts below.

## Install

### Download

1. Download **GcloudBar.zip** from the [latest release](../../releases/latest).
   It's a universal build that runs on both Apple silicon and Intel.
2. Unzip it and move **GcloudBar.app** to `/Applications` (or `~/Applications`).
3. Open it. If the release notes say the build isn't notarized, macOS refuses
   the first launch. Go to **System Settings → Privacy & Security**, click
   **Open Anyway** once, or run:
   ```sh
   xattr -dr com.apple.quarantine /Applications/GcloudBar.app
   ```
4. Turn on **Launch at login** in its menu. This only works while the app is in
   an Applications folder.

### Build from source

```sh
git clone https://github.com/michieltimmerman/gcloudbar.git && cd gcloudbar
packaging/build.sh                 # or: mise run build
open ~/Applications/GcloudBar.app
```

`build.sh` installs into `~/Applications`. If your keychain has an Apple
Development or Developer ID identity it signs with that, otherwise ad-hoc; both
run fine when built locally.

## What the menu shows

| Title      | Meaning                                                      |
|------------|--------------------------------------------------------------|
| `🔑 9h12m` | session works; estimated time left                           |
| `🔑`       | session works; no lapse seen yet, so nothing to predict      |
| `⚠️ 12m`   | inside the renewal window (Settings → Renew ahead of expiry) |
| `🔑 ~`     | past the estimate, but a check still got a token             |
| `🔒`       | lapsed or revoked: needs a browser login                     |
| `⏳`       | a login is open in your browser                              |
| `🔑 ?`     | gcloud not found, or the last check failed (offline)         |

The menu shows your account, the session status, what has been learned and the
last check. Its items are **Log in now** (or **Cancel login**), **Check now**,
**Settings…** (⌘,) and **Quit**.

## Settings

**General** tab:
- **Renew automatically.**
- **Renew ahead of expiry:** 15 minutes to 4 hours; 1 hour by default.
- **Session length until learned:** the guess used until a lapse has been seen.
- **Forget:** clears what has been learned, for example after the policy changed.
- **Open login pages in:** any installed browser, or the default browser.
- **Also renew ADC.**
- **Notifications.**
- **Launch at login.**

**gcloud** tab:
- **Compatibility**, with a **Check now** button: whether your gcloud still has
  everything GcloudBar relies on (see
  [Relying on gcloud internals](#relying-on-gcloud-internals)).
- The detected gcloud, Python, account and config folder. You can override each
  path with **Choose…**, or set it back to **Automatic** with **Reset**.

### Command-line arguments

Every setting can also be given on the command line for a single run. An
argument wins over the Settings window, is shown there greyed out ("Set by …
for this run"), and is never saved:

```sh
open -a GcloudBar --args --renew-ahead 2h --login-browser default
~/Applications/GcloudBar.app/Contents/MacOS/GcloudBar --help
```

| Argument | Setting |
|---|---|
| `--auto-renew on\|off` | Renew automatically |
| `--renew-ahead DURATION` | Renew ahead of expiry, e.g. `30m`, `2h`, `1h30m` |
| `--session-length DURATION` | Session length until learned, e.g. `16h` |
| `--login-browser ID\|default` | Open login pages in (a bundle id, or the default browser) |
| `--renew-adc on\|off` | Also renew ADC |
| `--notifications on\|off` | Notifications |
| `--gcloud PATH`, `--python PATH`, `--gcloud-config DIR` | the gcloud tab's overrides |

Commands that print something and exit:
- `--status`: what GcloudBar sees, offline;
- `--compat [SDK_DIR]`: the compatibility check;
- `--version` and `--help`.

## How expiry is worked out

gcloud stores no session deadline: a fresh login keeps no RAPT token, and the
policy length lives on Google's side. So **expiry = last login + session
length**.

- **Last login** comes from two places: the app's own logins, and a scan of
  gcloud's per-invocation logs (`<gcloud config dir>/logs/<day>/<time>.log`) for a
  completed `gcloud auth login` of the account being checked. So a plain
  `gcloud auth login` in a terminal counts too. `--brief` and `--no-activate`
  logins log no success line; for those, the next check notices that a lapsed
  session works again.
- **Per account:** switching gcloud's active account starts over, since a
  different account may have a different policy.
- **Session length** starts at the menu's guess (16h by default). Every 10 minutes
  a check runs `gcloud auth print-access-token --scopes=…`. The hidden `--scopes`
  flag forces a real refresh without touching gcloud's token cache, and the token
  printed on stdout is discarded unread. Each check narrows the real length:
  "still worked at age A" and "lapsed by age B". The estimate is the menu value
  clamped into [A, B].
- **No policy, no predictions.** Without session control a refresh token never
  lapses. So GcloudBar predicts nothing until it has seen one real lapse. Until
  then it only reacts when the session actually lapses, and never prompts early.

## When it logs you in

With **Renew automatically** on, it runs
`gcloud auth login --force <account> --no-activate`. That happens an hour before
the estimated expiry (Settings → **Renew ahead of expiry**), or as soon as a check
finds the session lapsed. It only happens while someone is at the Mac: screen
unlocked, input in the last 2 minutes.

Renewing well ahead matters when an agent keeps using gcloud after you've walked
away: only you can approve the renewal, so it is best done while you're still
there.

- The login page opens in **Google Chrome** when it's installed, and in your
  default browser otherwise (menu: **Open logins in Google Chrome**). gcloud
  opens its page through Python's `webbrowser`, so GcloudBar sets `$BROWSER` to
  itself and passes the URL to `open -b com.google.Chrome`. That avoids
  Python's AppleScript route, which would trigger a macOS Automation prompt.
- A lapse that happens overnight is renewed when you unlock in the morning.
- A login nobody approves is stopped after 5 minutes. It is retried after 30
  minutes, or when you unlock or wake the Mac. A display waking up doesn't
  count, so nudging the mouse won't reopen it.
- No check runs while a login is open. Quitting GcloudBar stops an open login.
- If checks keep failing for half an hour (offline, gcloud broken), you get one
  notification saying why. If gcloud's Python disappears, for example after a
  mise or pyenv upgrade, it finds another by itself.
- With it off, you get notifications before and at the lapse instead.

**Also renew ADC** runs `gcloud auth application-default login` after the gcloud
login. That is a second browser approval, because Application Default
Credentials are a separate OAuth client with their own session. If your ADC file
impersonates a service account, the renewal keeps it, including any delegation
chain.

## With service-account impersonation (e.g. AI agents)

A common setup lets an AI coding agent use gcloud only as a dedicated service
account, while you keep using your own account. Scope the impersonation to the
agent's environment rather than to gcloud's config:

- **Do:** set it in the agent's environment only, e.g. Claude Code's
  `settings.json` → `"env"`:
  ```sh
  CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT=agent@project.iam.gserviceaccount.com
  GOOGLE_IMPERSONATE_SERVICE_ACCOUNT=agent@project.iam.gserviceaccount.com   # Terraform
  ```
  Both are standard, documented variables:
  - **gcloud** reads any property from `CLOUDSDK_<SECTION>_<PROPERTY>`.
  - **The Terraform Google provider** reads `GOOGLE_IMPERSONATE_SERVICE_ACCOUNT`
    for its `impersonate_service_account`.
- **Don't:** `gcloud config set auth/impersonate_service_account …` impersonates
  in *every* shell, yours included.

Impersonation uses your user login as its source credential, so keeping that
login alive keeps the agent working too. GcloudBar leaves the setup alone:

- **Checks** run as you, with impersonation switched off for that one call
  (`CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT=""`). Otherwise gcloud would ignore
  `--scopes` and answer from its token cache, up to an hour late.
- **Logins** use `--no-activate`, so no gcloud configuration is rewritten. The
  one exception is when gcloud has no account configured at all: then the login
  sets the account you pick, as `gcloud auth login` normally does.
- **ADC:** `--update-adc` is never used, because it would replace an impersonated
  ADC with plain user credentials.

## Privacy

GcloudBar only runs gcloud, which talks to Google. It sends nothing anywhere else
and has no telemetry. Its own gcloud calls also run with gcloud's usage
reporting and update check turned off; your gcloud settings stay as they are. It
reads:

- gcloud's local log files (the first 4 KB of each, more for `auth login` logs);
- your ADC file, of which only the impersonation entries are used;
- its own state file (`~/Library/Application Support/GcloudBar/state.json`).

Access tokens are never read: the check's stdout goes to `/dev/null`.

## Finding gcloud and Python

GUI apps don't inherit your shell environment, and gcloud refuses macOS's own
Python 3.9. GcloudBar doesn't source your shell rc files to find
`CLOUDSDK_PYTHON`, since they can be slow or prompt for an SSH passphrase.
Instead it tries Pythons until a local `gcloud config get account` loads, in this
order:

1. the Python chosen in Settings, or `CLOUDSDK_PYTHON` (see [Configuration](#configuration))
2. the one that worked last time
3. gcloud's own pick
4. every Python ≥ 3.10 from mise, pyenv, asdf, Homebrew or python.org, newest first

The winner is remembered. `GcloudBar --status` prints what it finds without
contacting anything: the only gcloud it runs is a local `config get account`.

gcloud itself is looked for in these places, unless you chose one in Settings:
- `~/google-cloud-sdk`
- Homebrew (both prefixes)
- MacPorts
- Nix
- mise and asdf installs

If gcloud isn't found, the app looks again each time the Mac wakes or is
unlocked.

## Configuration

Everything is set in the **Settings** window, or for one run with
[command-line arguments](#command-line-arguments). The path overrides and the
login browser are stored in the app's defaults under these keys. You can also
script them with `defaults write com.michieltimmerman.gcloudbar KEY value`. An
environment variable of the same name overrides them too; tests use that.
Precedence: argument, then environment, then Settings.

| Key | Settings field |
|---|---|
| `GCLOUDBAR_GCLOUD` | gcloud |
| `CLOUDSDK_PYTHON` | Python for gcloud (vetted like any other candidate) |
| `CLOUDSDK_CONFIG` | gcloud config folder (logs, ADC), as for gcloud itself |
| `GCLOUDBAR_LOGIN_BROWSER` | Open login pages in. Any bundle id works, e.g. `com.google.Chrome.beta`. |

Environment only (development and tests):

| Variable | Effect |
|---|---|
| `GCLOUDBAR_STATE` | state file location |
| `GCLOUDBAR_DEBUG=1` | log decisions to stderr |
| `GCLOUDBAR_BUNDLE_ID`, `CODESIGN_IDENTITY`, `VERSION`, `UNIVERSAL=1` | build-time: bundle id, signing identity, version, universal binary |

## Development and tests

```sh
mise run app      # build into ~/Applications and (re)launch
mise run test     # build, then tests/e2e.sh (~2 min)
mise run state    # what the app has learned
tests/real-smoke.sh [service-account]
```

- **`tests/e2e.sh`** runs the real app binary, menu bar item and all, against
  `tests/fake-gcloud` with every interval 120× faster. It covers:
  - picking up terminal logins;
  - renewing and warning;
  - abandoned, cancelled and retried logins;
  - ADC renewal;
  - offline and revoked states, including the notice when checks keep failing;
  - Python discovery, and recovery when the Python disappears mid-run;
  - account switching, no checks during a login, quitting stopping a login;
  - the Chrome hand-off and the Settings window;
  - the `--scopes` fallback and a reworded lapse error;
  - command-line arguments, and the compatibility check (CLI and at launch);
  - the agent impersonation guarantees above.

  It never touches your gcloud config.
- **`tests/real-smoke.sh`** runs the installed app once against your real gcloud,
  with its own state file and auto-renew off. It diffs your gcloud config dir
  before and after: hashes of the config files, and only mtime and size of the
  credential files, which are never opened. It exits non-zero unless the check
  got a real answer from Google and nothing outside the token cache changed.

## Releasing

Releases are cut from a clean, pushed `main`. Both tasks first run the build
and the end-to-end suite.

```sh
mise run release -- 1.2.0         # tag v1.2.0 and push it; GitHub Actions builds and publishes
mise run release-local -- 1.2.0   # build here and publish with gh (no Actions)
```

- **`release`** triggers `.github/workflows/release.yml`. On macOS runners it
  builds a universal app and attaches `GcloudBar.zip` and a SHA-256 checksum to
  the release. The fixed file name keeps `releases/latest/download/GcloudBar.zip`
  a stable link.
- **Signing and notarization:** the build is signed with a Developer ID and
  notarized, so it opens without the Gatekeeper step, when the repository has
  these secrets (an Apple Developer Program membership is needed):
  - `MACOS_CERTIFICATE_P12`, `MACOS_CERTIFICATE_PASSWORD`, `MACOS_SIGNING_IDENTITY`
  - `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`

  Without them, the build is ad-hoc signed and the release notes explain the
  "Open Anyway" step.
- **`release-local`** signs with a Developer ID from your keychain if you have
  one, and ad-hoc otherwise. It never uses an Apple Development certificate,
  because that would put your personal Apple ID in every download.
- **CI:** `.github/workflows/ci.yml` builds and runs the end-to-end suite on
  every push and pull request. Standard macOS runners are free for public
  repositories.

## Relying on gcloud internals

Some of what GcloudBar uses isn't a public gcloud contract. None of it is a
single point of failure, and a weekly check catches changes early:

| Relies on | If gcloud changes it |
|---|---|
| hidden `--scopes` flag (refresh without touching the token cache) | falls back to the documented `config config-helper --force-auth-refresh`, which still forces a refresh |
| wording of the session-lapse error | recognised by six markers: message text, google-auth exception names, OAuth codes `invalid_rapt`/`rapt_required`. If all changed, the lapse reads as revoked: still renewed, just not learned from |
| log lines of a terminal `gcloud auth login` | such logins are then noticed by the next check instead (the session works again) |
| `exec "$CLOUDSDK_PYTHON"` in `bin/gcloud` (exit 127 when it's gone) | "gcloud failed to load" also triggers a new Python search |

**The app checks your installed gcloud for all of these.** gcloud ships as Python
source, so GcloudBar reads the few files these live in and reports which features
each one serves. The check runs:
- at launch, and whenever gcloud is found again;
- from **Settings → gcloud → Check now**;
- as `GcloudBar --compat [SDK_DIR]` (`mise run compat` in the repo).

If something is missing, Settings lists it, the menu shows a warning line, and
you get one notification per gcloud version.

`.github/workflows/gcloud-compat.yml` runs the same `--compat` every Monday
against the newest Google Cloud CLI, so an incompatible gcloud release shows up
as a failed run for the maintainer before users notice. GitHub pauses scheduled
workflows in repositories without activity for 60 days; re-enable it on the
Actions tab if that happens.

## License

MIT — see [LICENSE](LICENSE).
