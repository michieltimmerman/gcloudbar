// Lapse detection on use: every gcloud run writes a new log under
// <config>/logs/YYYY.MM.DD/, whose "Running [gcloud.<command>] with arguments: […]"
// line names the command. Watching that folder (FSEvents) sees gcloud being used
// by anything — a terminal, kubectl's gke-gcloud-auth-plugin, an agent — with no
// wrapper or shim, so the login is checked when it matters. Terraform and other
// tools that use Application Default Credentials without calling gcloud leave no log.
import CoreServices
import Foundation

/// Which gcloud runs count as using the login.
enum Usage {
    /// The command and its arguments line, from a log's first 16 KB; nil until
    /// gcloud has written the line.
    static func command(inLog url: URL) -> (command: String, line: String)? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let head = String(decoding: (try? h.read(upToCount: 16_384)) ?? Data(), as: UTF8.self)
        guard let r = head.range(of: "Running [gcloud.") else { return nil }
        let rest = head[r.upperBound...]
        guard let end = rest.firstIndex(of: "]") else { return nil }
        let line = rest.prefix { $0 != "\n" }
        return (String(rest[..<end]), String(line))
    }

    /// Local-only commands, logins, and GcloudBar's own probes don't count. The
    /// probe is the only caller passing the hidden --scopes flag to
    /// print-access-token, and the only one forcing a refresh through
    /// config-helper (kubectl's plugin calls config-helper without it).
    static func countsAsUse(command: String, line: String) -> Bool {
        let local = ["config.get", "config.list", "config.set", "config.unset", "config.configurations",
                     "auth.login", "auth.list", "auth.revoke", "auth.application-default",
                     "version", "info", "components", "help", "topic"]
        if local.contains(where: { command == $0 || command.hasPrefix($0 + ".") }) { return false }
        if command == "auth.print-access-token", line.contains("--scopes") { return false }
        if command == "config.config-helper", line.contains("force-auth-refresh") { return false }
        return true
    }
}

/// Calls `onUse` with the command each time a gcloud run that counts as use
/// starts writing its log.
final class UsageWatcher {
    private var stream: FSEventStreamRef?
    /// Logs already classified; a log is read until its "Running" line is in.
    private var classified = Set<String>()
    private let onUse: (String) -> Void

    init(onUse: @escaping (String) -> Void) {
        self.onUse = onUse
    }

    deinit { stop() }

    /// Watches the whole config folder: the logs folder may not exist yet.
    func start(configDir: URL) {
        stop()
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<UsageWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            me.changed(Array(list.prefix(count)))
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let s = FSEventStreamCreate(nil, callback, &ctx, [configDir.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                          0.3, flags) else {
            debug("usage: can't watch \(configDir.path)")
            return
        }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
        debug("usage: watching \(configDir.path)")
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    private func changed(_ paths: [String]) {
        if classified.count > 5000 { classified.removeAll() }
        for p in paths where p.hasSuffix(".log") && p.contains("/logs/") && !classified.contains(p) {
            guard let (command, line) = Usage.command(inLog: URL(fileURLWithPath: p)) else { continue }
            classified.insert(p)
            if Usage.countsAsUse(command: command, line: line) { onUse(command) }
        }
    }
}
