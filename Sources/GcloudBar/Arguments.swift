// Command-line arguments. Every setting in the Settings window can also be given
// for one run — `open -a GcloudBar --args --renew-ahead 2h`, or the binary itself
// — and an argument wins over the environment, which wins over Settings. Arguments
// are never saved: for a lasting change, use Settings.
import Foundation

/// Settings given on the command line; nil means "not given".
struct Overrides {
    var gcloud: String?
    var python: String?
    var gcloudConfig: String?
    /// A bundle id, or "default" for the default browser.
    var loginBrowser: String?
    var autoRenew: Bool?
    var renewAheadMinutes: Double?
    var sessionHours: Double?
    var renewADC: Bool?
    var notifications: Bool?

    /// The path and browser settings, by their `setting()` key.
    func value(forSettingKey key: String) -> String? {
        switch key {
        case "GCLOUDBAR_GCLOUD": return gcloud
        case "CLOUDSDK_PYTHON": return python
        case "CLOUDSDK_CONFIG": return gcloudConfig
        case "GCLOUDBAR_LOGIN_BROWSER": return loginBrowser == "default" ? nil : loginBrowser
        default: return nil
        }
    }

    /// The flag that set a `setting()` key, for "set by --gcloud" notes.
    static func flag(forSettingKey key: String) -> String? {
        ["GCLOUDBAR_GCLOUD": "--gcloud", "CLOUDSDK_PYTHON": "--python",
         "CLOUDSDK_CONFIG": "--gcloud-config", "GCLOUDBAR_LOGIN_BROWSER": "--login-browser"][key]
    }
}

struct Arguments {
    enum Command: Equatable {
        case run, help, version, status
        case compat(sdk: String?)
        /// `GcloudBar <url>`, as gcloud invokes it through $BROWSER.
        case openURL(String)
    }

    var command = Command.run
    var overrides = Overrides()

    struct Invalid: Error { let message: String }

    static let options: [(flag: String, value: String, help: String)] = [
        ("--gcloud", "PATH", "gcloud executable"),
        ("--python", "PATH", "Python for gcloud"),
        ("--gcloud-config", "DIR", "gcloud config folder (as CLOUDSDK_CONFIG)"),
        ("--login-browser", "ID|default", "browser for login pages, by bundle id"),
        ("--auto-renew", "on|off", "renew automatically"),
        ("--renew-ahead", "DURATION", "renew this long before expiry, e.g. 30m, 2h"),
        ("--session-length", "DURATION", "session length until learned, e.g. 16h"),
        ("--renew-adc", "on|off", "also renew Application Default Credentials"),
        ("--notifications", "on|off", "show notifications"),
    ]

    static let usage: String = {
        let width = options.map { $0.flag.count + $0.value.count + 1 }.max() ?? 0
        let lines = options.map { o -> String in
            let left = "\(o.flag) \(o.value)"
            return "  \(left)\(String(repeating: " ", count: width - left.count + 2))\(o.help)"
        }
        return """
        Usage: GcloudBar [options]
               GcloudBar --status | --compat [SDK_DIR] | --version | --help

        Settings for this run (they win over the Settings window and are not saved):
        \(lines.joined(separator: "\n"))

        Commands:
          --status            what GcloudBar sees: gcloud, Python, last login (offline)
          --compat [SDK_DIR]  check a gcloud install for what GcloudBar relies on
          --version           print the version
          --help              this text
        """
    }()

    /// Parses `CommandLine.arguments` (the executable path first). Cocoa's own
    /// `-Key value` pairs are skipped.
    static func parse(_ argv: [String]) throws -> Arguments {
        var a = Arguments()
        var rest = Array(argv.dropFirst())
        if rest.count == 1, let scheme = URL(string: rest[0])?.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            a.command = .openURL(rest[0])
            return a
        }
        while !rest.isEmpty {
            var arg = rest.removeFirst()
            if arg.hasPrefix("-"), !arg.hasPrefix("--") {
                if let next = rest.first, !next.hasPrefix("-") { rest.removeFirst() }
                continue
            }
            var inline: String?
            if let eq = arg.firstIndex(of: "=") {
                inline = String(arg[arg.index(after: eq)...])
                arg = String(arg[..<eq])
            }
            func value() throws -> String {
                if let inline { return inline }
                guard let v = rest.first, !v.hasPrefix("--") else {
                    throw Invalid(message: "\(arg) needs a value")
                }
                rest.removeFirst()
                return v
            }
            switch arg {
            case "--help", "-h": a.command = .help
            case "--version": a.command = .version
            case "--status": a.command = .status
            case "--compat":
                let sdk = inline ?? (rest.first.flatMap { $0.hasPrefix("--") ? nil : $0 })
                if inline == nil, sdk != nil { rest.removeFirst() }
                a.command = .compat(sdk: sdk)
            case "--gcloud": a.overrides.gcloud = try path(value(), arg)
            case "--python": a.overrides.python = try path(value(), arg)
            case "--gcloud-config": a.overrides.gcloudConfig = try path(value(), arg)
            case "--login-browser": a.overrides.loginBrowser = try value()
            case "--auto-renew": a.overrides.autoRenew = try bool(value(), arg)
            case "--renew-ahead": a.overrides.renewAheadMinutes = try minutes(value(), arg)
            case "--session-length": a.overrides.sessionHours = try minutes(value(), arg) / 60
            case "--renew-adc": a.overrides.renewADC = try bool(value(), arg)
            case "--notifications": a.overrides.notifications = try bool(value(), arg)
            default: throw Invalid(message: "unknown option \(arg)")
            }
        }
        return a
    }

    private static func path(_ v: String, _ flag: String) throws -> String {
        let expanded = NSString(string: v).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw Invalid(message: "\(flag): \(v) does not exist")
        }
        return expanded
    }

    private static func bool(_ v: String, _ flag: String) throws -> Bool {
        switch v.lowercased() {
        case "on", "true", "yes", "1": return true
        case "off", "false", "no", "0": return false
        default: throw Invalid(message: "\(flag) takes on or off, not \(v)")
        }
    }

    /// "90m", "2h", "1h30m" → minutes.
    private static func minutes(_ v: String, _ flag: String) throws -> Double {
        let pattern = #"^(?:(\d+)h)?(?:(\d+)m)?$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: v, range: NSRange(v.startIndex..., in: v)),
              !v.isEmpty else {
            throw Invalid(message: "\(flag) takes a duration like 30m, 2h or 1h30m, not \(v)")
        }
        func group(_ i: Int) -> Double {
            Range(m.range(at: i), in: v).flatMap { Double(v[$0]) } ?? 0
        }
        let total = group(1) * 60 + group(2)
        guard total > 0 else { throw Invalid(message: "\(flag) must be longer than zero") }
        return total
    }
}

/// This run's arguments; parsed first thing at launch.
var launchArguments = Arguments()
var overrides: Overrides { launchArguments.overrides }
