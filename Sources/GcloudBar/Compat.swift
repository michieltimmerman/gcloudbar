// What GcloudBar relies on in gcloud that isn't a public contract, checked against
// the installed SDK itself — gcloud ships as Python source — so a gcloud update that
// changes one shows up in Settings (and as one notification) instead of a feature
// quietly going missing. The app runs it at launch and when gcloud is found again;
// Settings has a button; `GcloudBar --compat [SDK]` prints it, which is what
// `mise run compat` and the weekly gcloud-compat workflow (newest gcloud) run.
import Foundation

enum Compat {
    struct Item {
        let ok: Bool
        /// A failure disables something; a warning only weakens it.
        let fatal: Bool
        let serves: String
        let detail: String
    }

    struct Report {
        let sdk: String
        let version: String
        let items: [Item]
        var failures: [Item] { items.filter { !$0.ok && $0.fatal } }
        var warnings: [Item] { items.filter { !$0.ok && !$0.fatal } }

        var summary: String {
            if failures.isEmpty, warnings.isEmpty {
                return "gcloud \(version): all \(items.count) checks pass"
            }
            return "gcloud \(version): \(failures.count) problem\(failures.count == 1 ? "" : "s"), "
                + "\(warnings.count) warning\(warnings.count == 1 ? "" : "s")"
        }
    }

    /// The SDK a gcloud executable belongs to: <sdk>/bin/gcloud, through symlinks
    /// (Homebrew's bin/gcloud points into the Caskroom).
    static func sdkRoot(gcloud: String) -> String? {
        let real = URL(fileURLWithPath: gcloud).resolvingSymlinksInPath()
        let root = real.deletingLastPathComponent().deletingLastPathComponent().path
        return FileManager.default.fileExists(atPath: root + "/lib/googlecloudsdk") ? root : nil
    }

    /// A fixed string, the files it may live in (any of them; gcloud reorganises —
    /// 591 split properties.py into a properties/ package), and the feature it serves.
    private static let needles: [(files: [String], needle: String, serves: String)] = [
        (["bin/gcloud"], #"exec "$CLOUDSDK_PYTHON""#,
         "a vanished Python shows up as exit 127 (Python is looked up again)"),
        (["lib/googlecloudsdk/core/properties.py", "lib/googlecloudsdk/core/properties/sections/auth.py"],
         "'impersonate_service_account'",
         "impersonation is switched off for the check (the auth property)"),
        (["lib/googlecloudsdk/core/properties.py", "lib/googlecloudsdk/core/properties/types.py"],
         "'CLOUDSDK_{section}_{name}'",
         "impersonation is switched off for the check (CLOUDSDK_AUTH_… variable)"),
        (["lib/googlecloudsdk/command_lib/auth/auth_util.py"], "cache_only_rapt",
         "the check leaves gcloud's token cache alone"),
        (["lib/googlecloudsdk/command_lib/auth/flags.py"], "'--scopes'",
         "the check forces a real refresh (hidden --scopes flag)"),
        (["lib/surface/config/config_helper.py"], "'--force-auth-refresh'",
         "fallback check if --scopes goes (config-helper --force-auth-refresh)"),
        (["lib/surface/auth/login.py"], "'--force'",
         "logins reopen the browser flow (auth login --force)"),
        (["lib/surface/auth/login.py"], "'--activate'",
         "logins leave your configuration alone (--no-activate)"),
        (["lib/surface/auth/login.py"], "You are now logged in as",
         "terminal logins are spotted in gcloud's logs (success line)"),
        (["lib/googlecloudsdk/calliope/base.py"], "Running [{}] with arguments",
         "terminal logins are spotted in gcloud's logs (command line)"),
        (["lib/googlecloudsdk/core/log.py"], "%Y.%m.%d",
         "gcloud's log folders are found"),
    ]

    /// Where gcloud's refresh errors are raised; the lapse markers (any of them)
    /// and invalid_grant are looked for across these.
    private static let credentialFiles = [
        "lib/googlecloudsdk/core/credentials/google_auth_credentials.py",
        "lib/googlecloudsdk/core/credentials/store.py",
        "lib/third_party/google/auth/exceptions.py",
        "lib/third_party/google/oauth2/reauth.py",
    ]

    static func check(sdk: String) -> Report {
        func read(_ file: String) -> String {
            (try? String(contentsOfFile: "\(sdk)/\(file)", encoding: .utf8)) ?? ""
        }
        var items = needles.map { n in
            Item(ok: n.files.contains { read($0).contains(n.needle) }, fatal: true, serves: n.serves,
                 detail: "\(n.needle) is no longer in \(n.files.joined(separator: " or "))")
        }
        let credentialText = credentialFiles.map(read).joined(separator: "\n")
        let markers = Probe.reauthMarkers
        let missing = markers.filter { !credentialText.contains($0) }
        items.append(Item(ok: missing.isEmpty, fatal: missing.count == markers.count,
                          serves: "the session lapse is recognised",
                          detail: missing.count == markers.count
                              ? "none of its \(markers.count) markers remain"
                              : "\(markers.count - missing.count) of \(markers.count) markers remain (gone: \(missing.joined(separator: ", ")))"))
        items.append(Item(ok: credentialText.contains("invalid_grant"), fatal: true,
                          serves: "revoked credentials are recognised",
                          detail: "'invalid_grant' is gone"))
        let version = read("VERSION").trimmingCharacters(in: .whitespacesAndNewlines)
        return Report(sdk: sdk, version: version.isEmpty ? "(unknown version)" : version, items: items)
    }

    /// `GcloudBar --compat [SDK]`: the SDK given, else the one of the gcloud the app
    /// would use. Exit 0 compatible, 1 problems found, 2 no SDK.
    static func runCLI(sdk: String?) -> Int32 {
        let root = sdk.map { NSString(string: $0).expandingTildeInPath }
            ?? Toolchain.resolve(remembered: State.load().python).flatMap { sdkRoot(gcloud: $0.gcloud) }
        guard let root, FileManager.default.fileExists(atPath: root + "/lib/googlecloudsdk") else {
            FileHandle.standardError.write("no Google Cloud SDK found\(sdk.map { " at \($0)" } ?? "")\n"
                .data(using: .utf8)!)
            return 2
        }
        let report = check(sdk: root)
        print("Google Cloud SDK at \(root)")
        for item in report.items {
            let tag = item.ok ? "ok   " : item.fatal ? "FAIL " : "warn "
            print("  \(tag) \(item.serves)\(item.ok ? "" : " — \(item.detail)")")
        }
        print("\n\(report.summary)")
        return report.failures.isEmpty ? 0 : 1
    }
}
