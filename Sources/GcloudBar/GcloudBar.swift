// GcloudBar — macOS menu bar item that keeps the gcloud CLI login from lapsing.
//
// The Google Workspace "Google Cloud session control" policy rejects gcloud's
// refresh token a fixed time after the last interactive `gcloud auth login` (the
// admin picks it; 16h is common), with "Reauthentication failed. cannot prompt
// during non-interactive execution". Nothing can renew that unattended — the
// browser + 2FA step is the point — so the app's job is to know when it lapses and
// put the login in front of you first.
//
// Expiry is not stored anywhere: a fresh login keeps no RAPT and gcloud never
// records a session deadline, so expiry = last login + session length.
//   - Last login: the app's own logins, plus a scan of gcloud's per-invocation logs
//     for a completed `gcloud auth login` you ran yourself.
//   - Session length: the guess from the menu, narrowed by probes. A probe is a
//     forced refresh (`print-access-token --scopes=…` skips the token cache and
//     leaves it untouched) every 10 minutes; "still worked at age A" and "lapsed
//     by age B" bound the real length.
//   - Without such a policy refresh tokens never lapse, so nothing is predicted
//     until a lapse has actually been seen once; until then the app only reacts.
//
// Service-account impersonation (e.g. an AI agent's gcloud running as a dedicated
// SA via CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT) rides on this same user login,
// so renewing it keeps the agent working. The app never changes that setup: the
// probe forces impersonation off for its own call only, logins use --no-activate so
// no configuration is rewritten, and it never uses --update-adc (which replaces an
// impersonated ADC with plain user credentials).
//
// Notifications use UNUserNotificationCenter when macOS allows it (it refuses
// ad-hoc signed apps), else terminal-notifier when installed, else osascript.
import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

let appEnv = ProcessInfo.processInfo.environment
/// Test hook (tests/e2e.sh): GCLOUDBAR_TIME_SCALE=120 runs every interval 120x faster.
let timeScale = max(1, Double(appEnv["GCLOUDBAR_TIME_SCALE"] ?? "") ?? 1)
let tickEvery: TimeInterval = 30 / timeScale
let probeEvery: TimeInterval = 600 / timeScale
/// `gcloud auth login` waits on its localhost redirect with no timeout of its own.
let loginTimeout: TimeInterval = 300 / timeScale
/// After an abandoned or failed automatic login, wait this long (or for the next
/// wake/unlock) before opening another browser tab.
let retryAfter: TimeInterval = 30 * 60 / timeScale
/// Only start an automatic login when someone is at the keyboard.
let idleLimit: TimeInterval = 120
let debugOn = appEnv["GCLOUDBAR_DEBUG"] == "1"

func debug(_ msg: @autoclosure () -> String) {
    guard debugOn else { return }
    FileHandle.standardError.write("[gcloudbar] \(msg())\n".data(using: .utf8)!)
}

/// A path or browser setting: a command-line argument wins (Arguments.swift), then
/// the environment (tests), then the app's defaults, which the Settings window
/// writes (and `defaults write com.michieltimmerman.gcloudbar KEY value` can too).
func setting(_ key: String) -> String? {
    if let v = overrides.value(forSettingKey: key) { return v }
    if let v = appEnv[key], !v.isEmpty { return v }
    if let v = UserDefaults.standard.string(forKey: key), !v.isEmpty { return v }
    return nil
}

/// gcloud's config directory; the CLOUDSDK_CONFIG setting moves it, for gcloud and
/// for tests. Read on every use so a change in Settings applies at once.
var gcloudConfigDir: URL {
    URL(fileURLWithPath: setting("CLOUDSDK_CONFIG") ?? NSString(string: "~/.config/gcloud").expandingTildeInPath)
}

func hms(_ seconds: TimeInterval) -> String {
    let s = Int(abs(seconds))
    if s >= 3600 { return String(format: "%dh%02dm", s / 3600, (s % 3600) / 60) }
    if s >= 60 { return "\(s / 60)m" }
    return "\(s)s"
}

func clock(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "EEE HH:mm"
    return f.string(from: date)
}

// MARK: - Running gcloud

struct Ran {
    var status: Int32 = -1
    var output = ""
    var timedOut = false
    var ok: Bool { status == 0 && !timedOut }
}

enum Capture { case stdout, stderr }

/// Runs a tool to completion, capturing one stream; the other goes to /dev/null so
/// no pipe can fill and stall the child. stdin is /dev/null so gcloud's copy-paste
/// fallback flows fail fast instead of waiting forever.
func runTool(_ path: String, _ args: [String], env: [String: String], capture: Capture,
             timeout: TimeInterval, started: ((Process) -> Void)? = nil) -> Ran {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: path)
    proc.arguments = args
    proc.environment = env
    proc.standardInput = FileHandle.nullDevice
    let pipe = Pipe()
    proc.standardOutput = capture == .stdout ? pipe : FileHandle.nullDevice
    proc.standardError = capture == .stderr ? pipe : FileHandle.nullDevice
    do { try proc.run() } catch { return Ran(output: error.localizedDescription) }
    started?(proc)
    let begun = Date()
    let killer = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    killer.cancel()
    return Ran(status: proc.terminationStatus,
               output: String(decoding: data, as: UTF8.self),
               timedOut: proc.terminationReason == .uncaughtSignal
                   && Date().timeIntervalSince(begun) >= timeout * 0.95)
}

struct Toolchain {
    let gcloud: String
    let python: String?

    /// GUI apps don't inherit the shell's environment, and gcloud refuses macOS's
    /// /usr/bin/python3 (3.9). Reading CLOUDSDK_PYTHON by sourcing ~/.zshrc proved
    /// fragile — it runs keychain, compinit and friends and can stall on an SSH
    /// passphrase — so each candidate is tried with a local `gcloud config get
    /// account` and the first gcloud loads with wins: CLOUDSDK_PYTHON from the
    /// app's environment, the one that worked last time, gcloud's own pick, then
    /// every Python ≥ 3.10 from mise, pyenv, asdf, Homebrew or python.org, newest
    /// first. The GCLOUDBAR_GCLOUD and CLOUDSDK_PYTHON settings take precedence.
    static func resolve(remembered: String? = nil) -> Toolchain? {
        let home = NSHomeDirectory()
        let fm = FileManager.default
        let mise = appEnv["MISE_DATA_DIR"] ?? "\(home)/.local/share/mise"
        // Version-manager installs, newest version first.
        let managed = ["\(mise)/installs/gcloud", "\(home)/.asdf/installs/gcloud"].flatMap { dir in
            ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
                .map { "\(dir)/\($0)/bin/gcloud" }
        }
        let gcloud = ([setting("GCLOUDBAR_GCLOUD"), "\(home)/google-cloud-sdk/bin/gcloud",
                       "/opt/homebrew/bin/gcloud", "/opt/homebrew/share/google-cloud-sdk/bin/gcloud",
                       "/usr/local/bin/gcloud", "/usr/local/share/google-cloud-sdk/bin/gcloud",
                       "/opt/local/bin/gcloud", "\(home)/.nix-profile/bin/gcloud",
                       "/run/current-system/sw/bin/gcloud", "/nix/var/nix/profiles/default/bin/gcloud"]
                      + managed)
            .compactMap { $0 }
            .first { fm.isExecutableFile(atPath: $0) }
        guard let gcloud else { return nil }
        var candidates: [String?] = [setting("CLOUDSDK_PYTHON"), remembered]
            .compactMap { $0 }.filter { !$0.isEmpty }
        candidates.append(nil)
        candidates += installedPythons()
        var tried = Set<String>()
        for py in candidates where tried.insert(py ?? "").inserted {
            let tc = Toolchain(gcloud: gcloud, python: py)
            let ok = tc.run(["config", "get", "account"], capture: .stdout, timeout: 30).ok
            debug("python \(py ?? "(gcloud's default)"): \(ok ? "gcloud loads" : "unusable")")
            if ok { return tc }
        }
        // Nothing loads; the probe will surface gcloud's own error in the menu.
        return Toolchain(gcloud: gcloud, python: nil)
    }

    /// Python ≥ 3.10 interpreters from the usual version managers and installers,
    /// newest first.
    static func installedPythons() -> [String] {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let mise = appEnv["MISE_DATA_DIR"] ?? "\(home)/.local/share/mise"
        var found: [(minor: Int, name: String, path: String)] = []
        func add(_ version: String, _ path: String) {
            guard let r = version.range(of: #"^3\.\d+"#, options: .regularExpression),
                  let minor = Int(version[r].dropFirst(2)), minor >= 10,
                  fm.isExecutableFile(atPath: path) else { return }
            found.append((minor, version, path))
        }
        for dir in ["\(mise)/installs/python", "\(home)/.pyenv/versions",
                    "\(home)/.asdf/installs/python", "/Library/Frameworks/Python.framework/Versions"] {
            for v in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                add(v, "\(dir)/\(v)/bin/python3")
            }
        }
        for dir in ["/opt/homebrew/bin", "/usr/local/bin"] {
            for f in (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            where f.range(of: #"^python3\.\d+$"#, options: .regularExpression) != nil {
                add(String(f.dropFirst("python".count)), "\(dir)/\(f)")
            }
        }
        return found.sorted { ($0.minor, $0.name) > ($1.minor, $1.name) }.map(\.path)
    }

    var env: [String: String] {
        var e = ProcessInfo.processInfo.environment
        let dir = (gcloud as NSString).deletingLastPathComponent
        e["PATH"] = "\(dir):/usr/bin:/bin:/usr/sbin:/sbin"
        // nil removes an inherited CLOUDSDK_PYTHON, so "gcloud's own pick" is real.
        e["CLOUDSDK_PYTHON"] = python
        if let config = setting("CLOUDSDK_CONFIG") { e["CLOUDSDK_CONFIG"] = config }
        // The app's own calls: no update check (keeps --status offline) and no
        // usage metrics about probes. Neither touches the user's configuration.
        e["CLOUDSDK_COMPONENT_MANAGER_DISABLE_UPDATE_CHECK"] = "true"
        e["CLOUDSDK_CORE_DISABLE_USAGE_REPORTING"] = "true"
        return e
    }

    func run(_ args: [String], capture: Capture = .stderr, timeout: TimeInterval = 60,
             extraEnv: [String: String] = [:], started: ((Process) -> Void)? = nil) -> Ran {
        debug("gcloud \(args.joined(separator: " "))")
        let r = runTool(gcloud, args, env: env.merging(extraEnv) { $1 }, capture: capture,
                        timeout: timeout, started: started)
        debug("  -> exit \(r.status)\(r.timedOut ? " (timed out)" : "")")
        return r
    }

    var account: String? {
        let r = run(["config", "get", "account"], capture: .stdout, timeout: 30)
        let a = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.ok && !a.isEmpty ? a : nil
    }
}

enum Probe {
    case valid
    /// The session-control lapse: the case this app exists for.
    case reauth
    /// invalid_grant — revoked or otherwise dead, not a timing signal.
    case revoked
    /// gcloud itself can't start — its Python vanished (a mise or pyenv upgrade) or
    /// is unsupported. Says nothing about the session; the toolchain is looked up again.
    case broken(String)
    /// Offline and the like — says nothing about the session.
    case failed(String)

    /// The session-control lapse, recognised by independent markers — gcloud's
    /// message, google-auth's exception names, and Google's OAuth error codes — so
    /// one rewording doesn't blind the app. If all of them changed, the lapse would
    /// read as `.revoked` (invalid_grant): still renewed, just not learned from.
    /// Compat.swift checks the installed gcloud still contains them.
    static let reauthMarkers = ["Reauthentication failed", "reauth is required",
                                "ReauthFailError", "ReauthRequiredError",
                                "invalid_rapt", "rapt_required"]

    /// Always the user's own refresh token, forced past the token cache, even when
    /// gcloud impersonates the agent SA: an empty CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT
    /// reads as unset (with impersonation on, `--scopes` is ignored and the cached
    /// token answers). A --scopes refresh only writes the RAPT column of the cache,
    /// so the token impersonation runs on is left alone. GCLOUDBAR_PROBE_SA routes
    /// the probe through a service account instead (an agent testing the app).
    /// stdout carries a live access token and is never read.
    static func run(_ tc: Toolchain) -> Probe {
        let scopes = "--scopes=https://www.googleapis.com/auth/cloud-platform"
        var args = ["auth", "print-access-token", "--quiet", scopes]
        if let sa = appEnv["GCLOUDBAR_PROBE_SA"], !sa.isEmpty {
            args.append("--impersonate-service-account=\(sa)")
        }
        let noImpersonation = ["CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT": ""]
        var r = tc.run(args, extraEnv: noImpersonation)
        // --scopes is a hidden flag. Should a gcloud release drop it, force the
        // refresh through the documented `config config-helper --force-auth-refresh`
        // instead — only as a fallback, as it re-stores the credential — printing
        // just the expiry, so a lapse still shows up within minutes.
        if !r.ok, r.output.contains("unrecognized arguments"), r.output.contains("--scopes") {
            let helper = ["config", "config-helper", "--force-auth-refresh", "--quiet",
                          "--format=value(credential.token_expiry)"]
                + args.filter { $0.hasPrefix("--impersonate-service-account=") }
            r = tc.run(helper, extraEnv: noImpersonation)
        }
        if r.ok { return .valid }
        if reauthMarkers.contains(where: r.output.contains) { return .reauth }
        if r.output.contains("invalid_grant") { return .revoked }
        let line = r.output.split(separator: "\n")
            .first { $0.hasPrefix("ERROR:") }.map(String.init)
        // 126/127: bin/gcloud's `exec "$CLOUDSDK_PYTHON"` found nothing to run.
        if r.status == 126 || r.status == 127 || r.output.contains("gcloud failed to load") {
            return .broken(line ?? "gcloud could not start (exit \(r.status))")
        }
        return .failed(r.timedOut ? "timed out" : line ?? "exit \(r.status)")
    }
}

// MARK: - Login detection from gcloud's logs

/// gcloud writes one log per invocation as logs/YYYY.MM.DD/HH.MM.SS.ffffff.log
/// (local time), including the status lines it prints. A completed `gcloud auth
/// login` has both markers below; the file's mtime is when the browser flow
/// finished, i.e. when the session clock started.
///
/// Files are tracked by name and mtime, not a high-water mark: local-time names
/// don't sort reliably across DST and time-zone changes, and a login's log only
/// gets its success line once the browser step completes, however long that takes.
/// `--brief` and `--no-activate` logins never print that line; the probe still
/// notices those once a lapsed session works again.
struct LoginScanner {
    private var seen: [String: Date] = [:]

    static let started = "Running [gcloud.auth.login]"
    static let succeeded = "You are now logged in as ["

    static var logsDir: URL { gcloudConfigDir.appendingPathComponent("logs") }

    /// Folder names are Gregorian dates in ASCII digits, whatever the user's
    /// calendar and locale.
    static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy.MM.dd"
        return f
    }()

    /// Newest completed login of `account` (any account when nil) among log files
    /// that are new or changed since the last scan. Sessions last at most a day,
    /// so only the last few day-folders are looked at.
    mutating func scan(account: String?) -> (at: Date, account: String)? {
        let fm = FileManager.default
        let oldest = Self.dayFormat.string(from: Date().addingTimeInterval(-3 * 86400))
        guard let days = try? fm.contentsOfDirectory(atPath: Self.logsDir.path) else { return nil }
        var found: (at: Date, account: String)?
        var current: [String: Date] = [:]
        for d in days where d >= oldest && d.count == 10 {
            let dir = Self.logsDir.appendingPathComponent(d)
            guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for f in files where f.hasSuffix(".log") {
                let rel = "\(d)/\(f)"
                let url = dir.appendingPathComponent(f)
                guard let mtime = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate])
                        as? Date else { continue }
                current[rel] = mtime
                guard seen[rel] != mtime,
                      let h = try? FileHandle(forReadingFrom: url) else { continue }
                defer { try? h.close() }
                let head = String(decoding: (try? h.read(upToCount: 4096)) ?? Data(), as: UTF8.self)
                guard head.contains(Self.started) else { continue }
                // Login logs are a few KB; the cap guards against a pathological file.
                let rest = (try? h.read(upToCount: 2_000_000)) ?? Data()
                let text = head + String(decoding: rest, as: UTF8.self)
                guard let r = text.range(of: Self.succeeded) else { continue }
                let acct = String(text[r.upperBound...].prefix { $0 != "]" })
                guard account == nil || acct == account else { continue }
                if found == nil || mtime > found!.at { found = (mtime, acct) }
            }
        }
        // Files that rolled out of the window are forgotten.
        seen = current
        return found
    }
}

// MARK: - Notifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private var useNative = false
    /// Homebrew's prefix differs between Apple silicon and Intel Macs.
    private let fallback = ["/opt/homebrew/bin/terminal-notifier", "/usr/local/bin/terminal-notifier"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    func requestAuthorization() {
        guard Bundle.main.bundleIdentifier != nil, appEnv["GCLOUDBAR_NO_BANNERS"] != "1" else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { self.useNative = granted }
        }
    }

    func post(title: String, body: String, group: String = "gcloudbar") {
        debug("notify: \(title) — \(body)")
        if appEnv["GCLOUDBAR_NO_BANNERS"] == "1" { return }
        if useNative {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: group, content: content, trigger: nil))
            return
        }
        let proc = Process()
        if let fallback {
            proc.executableURL = URL(fileURLWithPath: fallback)
            proc.arguments = ["-title", title, "-message", body, "-group", group]
        } else {
            // Title and body travel as arguments, never inside the script text, so
            // gcloud's error lines can't break (or inject into) the AppleScript.
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", "on run argv",
                              "-e", "display notification (item 2 of argv) with title (item 1 of argv)",
                              "-e", "end run", title, body]
        }
        try? proc.run()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                               willPresent notification: UNNotification,
                               withCompletionHandler completion:
                                   @escaping (UNNotificationPresentationOptions) -> Void) {
        completion([.banner, .sound])
    }
}

// MARK: - State

/// Persisted in ~/Library/Application Support/GcloudBar/state.json (`mise run state`).
struct State: Codable {
    var lastLogin: Date?
    var account: String?
    /// Oldest session age at which a probe still got a token.
    var longestValid: TimeInterval = 0
    /// Youngest session age at which a probe hit the reauth wall.
    var shortestExpired: TimeInterval?
    var sessionHours: Double = 16
    var autoLogin = true
    var renewADC = false
    var notify = true
    /// The Python gcloud last loaded with (Toolchain.resolve tries it first).
    var python: String?
    /// Open login pages in LoginBrowser (Chrome) when it is installed.
    var useLoginBrowser = true
    /// Renew this long before the estimated expiry. Generous by default: an agent
    /// can keep using the session long after you've walked away, and only you can
    /// approve the renewal.
    var renewAheadMinutes: Double = 60

    /// gcloud versions already notified about a compatibility problem.
    var compatNotified: String?

    // What the app acts on: a command-line argument for this run wins over the
    // saved setting (which the Settings window edits). Never saved.
    var renewsAutomatically: Bool { overrides.autoRenew ?? autoLogin }
    var notifies: Bool { overrides.notifications ?? notify }
    var renewsADC: Bool { overrides.renewADC ?? renewADC }
    var opensLoginBrowser: Bool {
        overrides.loginBrowser.map { $0 != "default" } ?? useLoginBrowser
    }
    var leadTime: TimeInterval { (overrides.renewAheadMinutes ?? renewAheadMinutes) * 60 / timeScale }

    init() {}

    /// Missing keys keep their defaults, so an older state file (or a test
    /// fixture) still loads instead of silently resetting everything.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = State()
        lastLogin = try c.decodeIfPresent(Date.self, forKey: .lastLogin)
        account = try c.decodeIfPresent(String.self, forKey: .account)
        longestValid = try c.decodeIfPresent(TimeInterval.self, forKey: .longestValid) ?? d.longestValid
        shortestExpired = try c.decodeIfPresent(TimeInterval.self, forKey: .shortestExpired)
        sessionHours = try c.decodeIfPresent(Double.self, forKey: .sessionHours) ?? d.sessionHours
        autoLogin = try c.decodeIfPresent(Bool.self, forKey: .autoLogin) ?? d.autoLogin
        renewADC = try c.decodeIfPresent(Bool.self, forKey: .renewADC) ?? d.renewADC
        notify = try c.decodeIfPresent(Bool.self, forKey: .notify) ?? d.notify
        python = try c.decodeIfPresent(String.self, forKey: .python)
        useLoginBrowser = try c.decodeIfPresent(Bool.self, forKey: .useLoginBrowser) ?? d.useLoginBrowser
        renewAheadMinutes = try c.decodeIfPresent(Double.self, forKey: .renewAheadMinutes) ?? d.renewAheadMinutes
        compatNotified = try c.decodeIfPresent(String.self, forKey: .compatNotified)
    }

    /// GCLOUDBAR_STATE moves it (tests, and agent runs that must not seed yours).
    static let url: URL = {
        if let p = appEnv["GCLOUDBAR_STATE"], !p.isEmpty { return URL(fileURLWithPath: p) }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GcloudBar")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }()

    static func load() -> State {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: url)).flatMap { try? d.decode(State.self, from: $0) } ?? State()
    }

    func save() {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? e.encode(self).write(to: Self.url, options: .atomic)
    }

    /// The menu's guess, overruled by what the probes have actually seen.
    var sessionLength: TimeInterval {
        min(max((overrides.sessionHours ?? sessionHours) * 3600, longestValid), shortestExpired ?? .infinity)
    }

    /// Nothing is predicted until a lapse has been seen: without a session policy
    /// the refresh token never expires, and early logins would only be noise.
    var expiry: Date? {
        guard shortestExpired != nil else { return nil }
        return lastLogin.map { $0.addingTimeInterval(sessionLength) }
    }

    /// Feed one probe outcome into the bounds on the real session length.
    mutating func learn(valid: Bool, at now: Date) {
        guard let login = lastLogin, now > login else { return }
        let age = now.timeIntervalSince(login)
        if valid { longestValid = max(longestValid, age) }
        else { shortestExpired = min(shortestExpired ?? .infinity, age) }
        // Contradicting bounds mean the policy changed: keep only the newest fact.
        if let s = shortestExpired, longestValid >= s {
            if valid { shortestExpired = nil } else { longestValid = 0 }
        }
    }
}

/// The browser gcloud's login page opens in: Google Chrome when installed
/// (GCLOUDBAR_LOGIN_BROWSER takes another bundle id), else the default browser.
/// gcloud opens it through Python's `webbrowser`, which runs $BROWSER with the URL;
/// pointing that at this executable lets `openLoginURL` hand it to LaunchServices.
/// Python's own "chrome" entry would drive Chrome over AppleScript instead, which
/// costs an Automation permission prompt.
enum LoginBrowser {
    static var bundleID: String { setting("GCLOUDBAR_LOGIN_BROWSER") ?? "com.google.Chrome" }

    static var appURL: URL? { url(bundleID) }

    /// "Google Chrome", for display.
    static var name: String? { appURL.map(displayName) }

    /// Browsers offered in Settings, when installed. Any other bundle id still works
    /// through the GCLOUDBAR_LOGIN_BROWSER setting.
    static let known = ["com.google.Chrome", "com.google.Chrome.beta", "com.brave.Browser",
                        "com.microsoft.edgemac", "company.thebrowser.Browser",
                        "org.mozilla.firefox", "com.apple.Safari"]

    static var installed: [(id: String, name: String)] {
        known.compactMap { id in url(id).map { (id, displayName($0)) } }
    }

    private static func url(_ id: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
    }

    private static func displayName(_ url: URL) -> String {
        FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// Extra environment for a login run; empty means gcloud's default browser.
    static func env(enabled: Bool) -> [String: String] {
        guard enabled, appURL != nil, let me = Bundle.main.executablePath else { return [:] }
        return ["BROWSER": me]
    }
}

/// `GcloudBar <url>`, as invoked through $BROWSER: open the URL in the login
/// browser, falling back to the default one. GCLOUDBAR_OPEN_DRY_RUN=1 only prints
/// the command (tests).
func openLoginURL(_ url: String) -> Int32 {
    let attempts = (LoginBrowser.appURL != nil ? [["-b", LoginBrowser.bundleID, url]] : []) + [[url]]
    for args in attempts {
        if appEnv["GCLOUDBAR_OPEN_DRY_RUN"] == "1" {
            print("open \(args.joined(separator: " "))")
            return 0
        }
        let r = runTool("/usr/bin/open", args, env: appEnv, capture: .stderr, timeout: 30)
        if r.ok { return 0 }
    }
    return 1
}

/// The service-account chain an impersonated ADC file uses, so renewing ADC keeps
/// it — `gcloud auth login --update-adc` would overwrite it with plain user
/// credentials. `chain` is "delegate,…,target", the form
/// --impersonate-service-account takes. Without one, `application-default login`
/// still honours auth/impersonate_service_account. Only the two impersonation
/// keys of the file are used.
func adcImpersonation() -> (target: String, chain: String)? {
    let path = gcloudConfigDir.appendingPathComponent("application_default_credentials.json").path
    guard let data = FileManager.default.contents(atPath: path),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let url = json["service_account_impersonation_url"] as? String,
          let r = url.range(of: #"serviceAccounts/([^:/]+)"#, options: .regularExpression)
    else { return nil }
    let account = { (s: Substring) in String(s.dropFirst("serviceAccounts/".count)) }
    let target = account(url[r])
    let delegates = (json["delegates"] as? [String] ?? []).map { d in
        d.range(of: #"serviceAccounts/[^:/]+"#, options: .regularExpression).map { account(d[$0]) } ?? d
    }
    return (target, (delegates + [target]).joined(separator: ","))
}

func userPresent() -> Bool {
    if appEnv["GCLOUDBAR_ASSUME_PRESENT"] == "1" { return true }
    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
    let locked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    let idle = CGEventSource.secondsSinceLastEventType(
        .combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    return !locked && idle < idleLimit
}

// MARK: - Monitor

enum Health: Equatable {
    case unknown, valid, expired, revoked
    case failed(String)
}

final class Monitor: ObservableObject {
    static let shared = Monitor()

    @Published var state = State.load() { didSet { state.save() } }
    @Published var health = Health.unknown
    @Published var loggingIn = false
    @Published var lastCheck: Date?
    @Published var toolchainMissing = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// Why Launch at login isn't on, when macOS said no.
    @Published var launchAtLoginNote: String?
    /// The impersonated SA of the ADC file, for display; refreshed per check so
    /// views don't read the file on every redraw.
    @Published var adcTarget: String?
    /// What locate() settled on, for Settings.
    @Published var gcloudPath: String?
    @Published var pythonPath: String?
    /// The installed gcloud checked for what the app relies on (Compat.swift).
    @Published var compat: Compat.Report?
    /// Redrawn by the tick so countdowns move between probes.
    @Published var now = Date()

    private var toolchain: Toolchain?
    private var locating = false
    private var scanner = LoginScanner()
    private var probing = false
    /// Checks in a row that got no answer (offline, gcloud broken).
    private var failedChecks = 0
    private var loginProc: Process?
    private var loginCancelled = false
    /// "Log in now" clicked while gcloud is still being located (vetting Pythons
    /// takes a few seconds after launch); it runs as soon as the toolchain is known.
    private var loginQueued = false
    private var nextAutoAttempt: Date?
    /// When a probe first hit the reauth wall in the current lapse.
    private var lapsedAt: Date?
    /// The login a heads-up was already sent for, and whether the lapse was announced.
    private var warnedSoonFor: Date?
    private var warnedLapse = false
    private var timer: Timer?

    private var sigterm: DispatchSourceSignal?

    func start() {
        Notifier.shared.requestAuthorization()
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
            [weak self] _ in self?.cameBack()
        }
        // A display wake is not a return to the Mac: check, but keep the back-off,
        // or every mouse nudge would reopen an ignored login.
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) {
            [weak self] _ in self?.check()
        }
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in self?.cameBack() }

        // An open login must not outlive the app: gcloud waits for the browser forever.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.loginProc?.terminate() }
        signal(SIGTERM, SIG_IGN)
        sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm?.setEventHandler { [weak self] in
            self?.loginProc?.terminate()
            exit(0)
        }
        sigterm?.resume()

        if Bundle.main.bundlePath.contains("/AppTranslocation/") {
            launchAtLoginNote = "Move GcloudBar to Applications to enable Launch at login"
        }
        locate()
        timer = Timer.scheduledTimer(withTimeInterval: tickEvery, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    /// Find gcloud and a Python it loads with, off the main thread, then check.
    /// Also run when Settings changes the gcloud, Python or config-folder override.
    func locate() {
        guard !locating else { return }
        locating = true
        let remembered = state.python
        DispatchQueue.global(qos: .utility).async {
            let tc = Toolchain.resolve(remembered: remembered)
            debug("toolchain gcloud=\(tc?.gcloud ?? "nil") python=\(tc?.python ?? "nil")")
            DispatchQueue.main.async {
                self.locating = false
                self.toolchain = tc
                self.toolchainMissing = tc == nil
                self.gcloudPath = tc?.gcloud
                self.pythonPath = tc?.python
                self.checkCompat()
                if let py = tc?.python, py != self.state.python { self.state.python = py }
                if self.loginQueued {
                    self.loginQueued = false
                    self.login()
                }
                self.check()
            }
        }
    }

    /// Check the gcloud in use for what the app relies on (launch, re-detection,
    /// Settings → Check now). One notification per gcloud version with a problem.
    func checkCompat() {
        guard let gcloud = toolchain?.gcloud else {
            compat = nil
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let report = Compat.sdkRoot(gcloud: gcloud).map { Compat.check(sdk: $0) }
            DispatchQueue.main.async {
                self.compat = report
                guard let report else {
                    debug("compat: \(gcloud) is not inside a Google Cloud SDK; not checked")
                    return
                }
                debug("compat: \(report.summary)")
                if let first = report.failures.first, self.state.notifies,
                   self.state.compatNotified != report.version {
                    self.state.compatNotified = report.version
                    Notifier.shared.post(title: "gcloud \(report.version) changed something GcloudBar relies on",
                                         body: "\(first.serves): \(first.detail). See Settings → gcloud.",
                                         group: "gcloudbar-compat")
                }
            }
        }
    }

    /// Settings moved the gcloud config folder: other logs, maybe another account.
    func configFolderChanged() {
        scanner = LoginScanner()
        locate()
    }

    /// Settings → forget the learned session length (after a policy change, say).
    func resetLearned() {
        state.longestValid = 0
        state.shortestExpired = nil
        lapsedAt = nil
        warnedSoonFor = nil
    }

    /// System wake or unlock: a lapse that happened overnight is the usual case, and
    /// a declined login earlier shouldn't block the fresh attempt.
    private func cameBack() {
        nextAutoAttempt = nil
        // Installed gcloud while the Mac slept, say.
        if toolchainMissing { locate() }
        // The network needs a moment after wake.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10 / timeScale) { self.check() }
    }

    private func tick() {
        now = Date()
        readInbox()
        scanLogs()
        if !probing, !loggingIn, (lastCheck.map { now.timeIntervalSince($0) >= probeEvery } ?? true) {
            check()
        }
        maybeRenew()
        warnIfManual()
    }

    /// Test hook: GCLOUDBAR_TEST_INBOX names a file of menu actions (login, cancel,
    /// check, settings; one per line), consumed on the next tick — a script can't
    /// click the menu.
    private func readInbox() {
        guard let path = appEnv["GCLOUDBAR_TEST_INBOX"],
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(atPath: path)
        for action in text.split(separator: "\n") {
            debug("inbox: \(action)")
            switch action {
            case "login": login()
            case "cancel": cancelLogin()
            case "check": check()
            case "settings": SettingsWindow.shared.show(tab: "general")
            case "settings gcloud": SettingsWindow.shared.show(tab: "gcloud")
            default: break
            }
        }
    }

    /// Only logins of the checked account count; another account's login says
    /// nothing about this session.
    private func scanLogs() {
        guard let hit = scanner.scan(account: state.account) else { return }
        if state.lastLogin.map({ hit.at > $0 }) ?? true {
            debug("login found in gcloud logs: \(hit.account) at \(hit.at)")
            state.lastLogin = hit.at
            if state.account == nil { state.account = hit.account }
            if health == .expired || health == .revoked { health = .unknown }
        }
    }

    /// Probe now (menu, wake, unlock, after a login) or on the 10-minute cadence.
    /// Never during a login: the answer would describe the session being replaced.
    func check() {
        guard let tc = toolchain, !probing, !loggingIn else { return }
        probing = true
        let started = Date()
        DispatchQueue.global(qos: .utility).async {
            let account = tc.account
            let result = Probe.run(tc)
            DispatchQueue.main.async { self.apply(result, account: account, started: started) }
        }
    }

    private func apply(_ result: Probe, account: String?, started: Date) {
        probing = false
        let at = Date()
        // A login (ours or a terminal one) since the check began makes its answer
        // stale — learning from it would record a lapse seconds into the new session.
        if loggingIn || (state.lastLogin.map { $0 > started } ?? false) {
            debug("probe: \(result) — discarded, the session changed meanwhile")
            if !loggingIn { check() }
            return
        }
        lastCheck = at
        now = at
        adcTarget = adcImpersonation()?.target
        if let a = account, a != state.account {
            if state.account != nil {
                // Switched gcloud accounts: what was learned belongs to the old one.
                debug("account changed to \(a); forgetting the previous session")
                state.lastLogin = nil
                state.longestValid = 0
                state.shortestExpired = nil
                lapsedAt = nil
                warnedSoonFor = nil
                scanner = LoginScanner()
            }
            state.account = a
        }
        scanLogs()
        debug("probe: \(result)")
        if case .failed = result { failedChecks += 1 } else if case .broken = result { failedChecks += 1 }
        else { failedChecks = 0 }
        switch result {
        case .valid:
            if let lapsed = lapsedAt, state.lastLogin.map({ $0 < lapsed }) ?? true {
                // Came back to life without a login the scan could date (e.g.
                // `--brief`): the session clock started somewhere since the lapse.
                state.lastLogin = at
            }
            lapsedAt = nil
            health = .valid
            state.learn(valid: true, at: at)
        case .reauth:
            if lapsedAt == nil {
                lapsedAt = at
                state.learn(valid: false, at: at)
            }
            health = .expired
        case .revoked:
            health = .revoked
        case .broken(let why):
            health = .failed(why)
            // Its Python went away (a mise or pyenv upgrade, say): look again.
            state.python = nil
            locate()
        case .failed(let why):
            health = .failed(why)
        }
        // Said once per streak: half an hour without an answer while it matters.
        if failedChecks == 3, state.notifies, case .failed(let why) = health {
            Notifier.shared.post(title: "GcloudBar can't check your gcloud login",
                                 body: why, group: "gcloudbar-failing")
        }
        maybeRenew()
        warnIfManual()
    }

    private var renewDue: Bool {
        switch health {
        case .expired, .revoked: return true
        case .valid: return state.expiry.map { now >= $0.addingTimeInterval(-state.leadTime) } ?? false
        default: return false
        }
    }

    private func maybeRenew() {
        guard state.renewsAutomatically, !loggingIn, toolchain != nil, renewDue,
              nextAutoAttempt.map({ now >= $0 }) ?? true, userPresent() else { return }
        login(auto: true)
    }

    /// With automatic renewal off, a heads-up before the lapse and a note at it.
    private func warnIfManual() {
        if health == .valid { warnedLapse = false }
        guard !state.renewsAutomatically, state.notifies else { return }
        if health == .expired || health == .revoked, !warnedLapse {
            warnedLapse = true
            Notifier.shared.post(title: "gcloud login lapsed",
                                 body: "Log in again from the 🔑 menu.")
        } else if health == .valid, warnedSoonFor != state.lastLogin,
                  let e = state.expiry, now >= e.addingTimeInterval(-state.leadTime) {
            warnedSoonFor = state.lastLogin
            Notifier.shared.post(title: "gcloud login lapses at ~\(clock(e))",
                                 body: "Log in from the 🔑 menu to restart the \(hms(state.sessionLength)) clock.")
        }
    }

    func login(auto: Bool = false) {
        guard !loggingIn else { return }
        guard let tc = toolchain else {
            if !toolchainMissing, !auto {
                loginQueued = true
                debug("login queued until gcloud is located")
            }
            return
        }
        loggingIn = true
        loginCancelled = false
        if state.notifies {
            var when = "starting a fresh session"
            if health == .expired || health == .revoked { when = "it has lapsed" }
            else if health == .valid, let e = state.expiry { when = "it lapses at ~\(clock(e))" }
            Notifier.shared.post(title: auto ? "Renewing gcloud login" : "gcloud login",
                                 body: "Approve it in your browser — \(when).",
                                 group: "gcloudbar-login")
        }
        let known = state.account
        let adc = state.renewsADC
        let browser = LoginBrowser.env(enabled: state.opensLoginBrowser)
        // The handle arrives a moment after launch; a Cancel clicked before that
        // still has to stop it.
        let track: (Process) -> Void = { p in
            DispatchQueue.main.async {
                self.loginProc = p
                if self.loginCancelled { p.terminate() }
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            // A login clicked before the first probe has no account yet; read it
            // rather than let gcloud activate whatever account the browser picks.
            let account = known ?? tc.account
            // --force: with an account argument gcloud otherwise reuses the stored
            // credential and never opens the browser. --no-activate: the account is
            // already the active one, so the gcloud configuration is not rewritten.
            var args = ["auth", "login", "--force", "--quiet"]
            if let a = account { args += [a, "--no-activate"] }
            var r = tc.run(args, timeout: loginTimeout, extraEnv: browser, started: track)
            // The session clock starts now, not after the ADC approval below.
            let loggedInAt = Date()
            var adcResult: Ran?
            if r.ok, adc {
                var adcArgs = ["auth", "application-default", "login", "--quiet"]
                if let chain = adcImpersonation()?.chain {
                    adcArgs.append("--impersonate-service-account=\(chain)")
                }
                adcResult = tc.run(adcArgs, timeout: loginTimeout, extraEnv: browser, started: track)
            }
            if r.output.isEmpty { r.output = "exit \(r.status)" }
            DispatchQueue.main.async { self.finishLogin(r, adc: adcResult, at: loggedInAt) }
        }
    }

    func cancelLogin() {
        loginQueued = false
        loginCancelled = true
        loginProc?.terminate()
    }

    private func finishLogin(_ r: Ran, adc: Ran?, at loggedInAt: Date) {
        loggingIn = false
        loginProc = nil
        if r.ok {
            state.lastLogin = loggedInAt
            health = .valid
            lapsedAt = nil
            nextAutoAttempt = nil
            if state.notifies {
                // No expiry to quote until a lapse has been seen; still say it worked.
                let until = state.expiry.map { "Good until ~\(clock($0))." } ?? "Session restarted."
                let adcNote = adc.map { $0.ok ? " ADC renewed too." : " ADC renewal did not finish." } ?? ""
                Notifier.shared.post(title: "gcloud login renewed", body: until + adcNote,
                                     group: "gcloudbar-login")
            }
        } else {
            nextAutoAttempt = Date().addingTimeInterval(retryAfter)
            if state.notifies, !loginCancelled {
                let why = r.timedOut ? "No browser approval within \(hms(loginTimeout))."
                    : r.output.split(separator: "\n").first { $0.hasPrefix("ERROR:") }
                        .map(String.init) ?? "gcloud exited with \(r.status)."
                Notifier.shared.post(title: "gcloud login not completed",
                                     body: "\(why) Next try in \(hms(retryAfter)), or when you unlock or wake the Mac.",
                                     group: "gcloudbar-login")
            }
        }
        check()
    }

    /// The system owns this state; the toggle snaps back to what is registered,
    /// and the menu says why when macOS refused.
    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLoginNote = nil
        } catch {
            launchAtLoginNote = "Launch at login: \(error.localizedDescription)"
        }
        if SMAppService.mainApp.status == .requiresApproval {
            launchAtLoginNote = "Allow GcloudBar under Login Items in System Settings"
            SMAppService.openSystemSettingsLoginItems()
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Menu text

    var title: String {
        if loggingIn { return "⏳" }
        if toolchainMissing { return "🔑 ?" }
        switch health {
        case .expired, .revoked: return "🔒"
        case .failed: return "🔑 ?"
        case .unknown: return "🔑 …"
        case .valid:
            guard let e = state.expiry else { return "🔑" }
            let left = e.timeIntervalSince(now)
            if left <= 0 { return "🔑 ~" }
            return left <= state.leadTime ? "⚠️ \(hms(left))" : "🔑 \(hms(left))"
        }
    }

    var statusLine: String {
        if toolchainMissing {
            return "gcloud not found — defaults write com.michieltimmerman.gcloudbar GCLOUDBAR_GCLOUD <path>"
        }
        let since = state.lastLogin.map { "logged in \(clock($0))" }
        switch health {
        case .unknown: return "Checking…"
        case .failed(let why): return "Check failed: \(why)"
        case .revoked: return "Credentials revoked — log in again"
        case .expired: return "Session lapsed" + (since.map { " · \($0)" } ?? "")
        case .valid:
            guard let since else {
                return "Session working · login time unknown until the next login"
            }
            guard let e = state.expiry else {
                return "\(since) · no lapse seen yet, so nothing to predict"
            }
            let left = e.timeIntervalSince(now)
            return left > 0
                ? "\(since) · lapses ~\(clock(e)) (in \(hms(left)))"
                : "\(since) · past the \(hms(state.sessionLength)) estimate, still working"
        }
    }

    var learnedLine: String {
        var parts = [state.shortestExpired == nil
            ? "Session limit: none seen yet" : "Session length ~\(hms(state.sessionLength))"]
        if state.longestValid > 0 { parts.append("worked at \(hms(state.longestValid))") }
        if let s = state.shortestExpired { parts.append("lapsed by \(hms(s))") }
        return parts.joined(separator: " · ")
    }

    var checkLine: String {
        guard let c = lastCheck else { return "Not checked yet" }
        return "Checked \(clock(c))" + (probing ? " · checking…" : "")
    }
}

// MARK: - CLI

/// `GcloudBar --status`: what the app would see, without contacting Google (the
/// only gcloud it runs is the local `config get account` that vets each Python).
func printStatus() {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let tc = Toolchain.resolve(remembered: State.load().python)
    print("gcloud:        \(tc?.gcloud ?? "not found")")
    print("python:        \(tc?.python ?? "(gcloud's default)")")
    var scanner = LoginScanner()
    if let hit = scanner.scan(account: nil) {
        print("last login:    \(f.string(from: hit.at)) as \(hit.account) (gcloud logs, last 3 days)")
    } else {
        print("last login:    none in gcloud logs of the last 3 days")
    }
    print("ADC impersonates: \(adcImpersonation()?.chain ?? "nothing (plain user ADC or none)")")
    print("login browser: \(LoginBrowser.name ?? "default browser (\(LoginBrowser.bundleID) not installed)")")
    let s = State.load()
    print("state:         \(State.url.path)")
    print("  lastLogin:   \(s.lastLogin.map(f.string) ?? "-")")
    print("  length:      \(hms(s.sessionLength)) (setting \(Int(s.sessionHours))h, worked at \(hms(s.longestValid)), lapsed by \(s.shortestExpired.map(hms) ?? "-"))")
    print("  expiry:      \(s.expiry.map(f.string) ?? "-")")
}

// MARK: - Menu

@main
struct GcloudBarApp: App {
    @StateObject private var monitor = Monitor.shared

    init() {
        do {
            launchArguments = try Arguments.parse(CommandLine.arguments)
        } catch let e as Arguments.Invalid {
            FileHandle.standardError.write("GcloudBar: \(e.message)\n\n\(Arguments.usage)\n".data(using: .utf8)!)
            exit(2)
        } catch {
            exit(2)
        }
        switch launchArguments.command {
        case .help:
            print(Arguments.usage)
            exit(0)
        case .version:
            print(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
            exit(0)
        case .status:
            printStatus()
            exit(0)
        case .compat(let sdk):
            exit(Compat.runCLI(sdk: sdk))
        case .openURL(let url):
            // Launched by gcloud through $BROWSER with the login URL.
            exit(openLoginURL(url))
        case .run:
            Monitor.shared.start()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            Text("gcloud · \(monitor.state.account ?? "no account")")
            Text(monitor.statusLine)
            Text(monitor.learnedLine)
            Text(monitor.checkLine)
            Divider()
            if monitor.loggingIn {
                Button("Cancel login") { monitor.cancelLogin() }
            } else {
                Button("Log in now") { monitor.login() }
            }
            Button("Check now") { monitor.check() }
            if let note = monitor.launchAtLoginNote { Text(note) }
            if let c = monitor.compat, !c.failures.isEmpty {
                Text("⚠︎ gcloud \(c.version) changed things GcloudBar relies on — see Settings")
            }
            Divider()
            Button("Settings…") { SettingsWindow.shared.show() }
                .keyboardShortcut(",")
            Button("Quit GcloudBar") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Text(monitor.title)
        }
    }
}
