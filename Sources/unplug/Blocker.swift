import Foundation

let pfAnchor = "com.apple/unplug"

/// The user's own file, not /tmp: whoever can write it picks the rules that get
/// loaded, and /etc/sudoers.d/unplug names this exact path.
let pfRulesPath = NSHomeDirectory() + "/.unplug/pf.rules"

/// pfctl needs root; nothing else here does. As root we exec it directly,
/// otherwise through `sudo -n`, which needs no password only for the exact
/// command forms /etc/sudoers.d/unplug allows. `run.sh` installs that rule
/// once, which is why the app itself no longer runs as root.
@discardableResult
func pfctl(_ args: [String]) -> (Int32, String) {
    getuid() == 0
        ? run("/sbin/pfctl", args)
        : run("/usr/bin/sudo", ["-n", "/sbin/pfctl"] + args)
}

func pfRules(hosts: Set<String>) -> String {
    hosts.sorted().map { host in
        host.contains(":")
            ? "block drop quick inet6 from any to \(host)"
            : "block drop quick from any to \(host)"
    }.joined(separator: "\n")
}

@discardableResult
func run(_ path: String, _ args: [String], input: String? = nil) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    if let input {
        let inp = Pipe()
        p.standardInput = inp
        do { try p.run() } catch { return (-1, "\(error)") }
        inp.fileHandleForWriting.write(Data(input.utf8))
        inp.fileHandleForWriting.closeFile()
    } else {
        do { try p.run() } catch { return (-1, "\(error)") }
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// Enforces blocks with pf, via the sub-anchor the stock /etc/pf.conf already
/// hooks ("anchor com.apple/*"), so no system file is edited.
///
/// Ceiling: pf matches packets, not processes, so a block is by remote address
/// and hits every app talking to that address; and an address is only known
/// after the app has reached it once, so the first connection leaks. True
/// per-app filtering needs a NEFilterDataProvider system extension with
/// Apple's networkextension entitlement — swap this type for that when the
/// app is signed for it.
final class Blocker {
    private var applied: Set<String> = []
    private var pfToken: String?
    private(set) var lastError: String?

    /// pfctl is reachable without a password prompt. Probed once at startup —
    /// reading the anchor is one of the allowed command forms.
    let canEnforce: Bool = pfctl(["-a", pfAnchor, "-s", "rules"]).0 == 0
    /// pf is actually holding the rules we asked for.
    var enforcing: Bool { canEnforce && lastError == nil }
    func isApplied(_ host: String) -> Bool { applied.contains(host) }

    /// Returns the hosts newly cut off, or nil when nothing changed.
    func apply(hosts: Set<String>, log: (String) -> Void) {
        guard hosts != applied else { return }
        let added = hosts.subtracting(applied)
        applied = hosts

        guard canEnforce else {
            lastError = "pfctl needs a password — pf rules not applied"
            log("pf: cannot enforce, run ./run.sh once (see README)")
            return
        }

        let rules = pfRules(hosts: hosts) + "\n"   // pfctl calls a missing final newline a syntax error
        do {
            try FileManager.default.createDirectory(
                atPath: (pfRulesPath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try rules.write(toFile: pfRulesPath, atomically: true, encoding: .utf8)
        } catch {
            lastError = "\(error)"
            log("pf: cannot write rules: \(error)")
            return
        }

        if pfToken == nil {
            let (_, out) = pfctl(["-E"])                  // refcounted enable
            pfToken = out.split(separator: "\n")
                .first { $0.contains("Token") }?
                .split(separator: ":").last?
                .trimmingCharacters(in: .whitespaces)
        }
        let (code, out) = pfctl(["-a", pfAnchor, "-f", pfRulesPath])
        if code != 0 {
            // pfctl always warns about -f and ALTQ on macOS; keep the real lines only
            let why = out.split(separator: "\n")
                .filter { $0.lowercased().contains("error") || $0.contains("not loaded") }
                .joined(separator: "; ")
            lastError = out
            log("pf: load failed: \(why.isEmpty ? out.trimmingCharacters(in: .whitespacesAndNewlines) : why)")
            return
        }
        lastError = nil
        log("pf: \(hosts.count) address\(hosts.count == 1 ? "" : "es") blocked")

        // New rules do not touch sockets that pf already has state for.
        for host in added {
            let any = host.contains(":") ? "::/0" : "0.0.0.0/0"
            pfctl(["-k", any, "-k", host])
            log("pf: killed live connections to \(host)")
        }
    }

    func flush(log: (String) -> Void) {
        guard canEnforce, !applied.isEmpty else { return }
        applied = []
        pfctl(["-a", pfAnchor, "-F", "rules"])
        if let pfToken { pfctl(["-X", pfToken]) }
        pfToken = nil
        log("pf: anchor flushed")
    }
}
