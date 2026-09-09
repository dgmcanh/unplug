import AppKit
import Combine
import SwiftUI

struct AppRow: Identifiable, Equatable {
    var id: String
    var name: String
    var pid: Int32
    var icon: NSImage?

    static func == (a: AppRow, b: AppRow) -> Bool { a.id == b.id && a.pid == b.pid }
}

@MainActor
final class Monitor: ObservableObject {
    @Published var apps: [AppRow] = []
    @Published var blocked: Set<String> = []
    @Published var status = ""

    /// so the app delegate can release pf on terminate
    static weak var shared: Monitor?

    private let blocker = Blocker()
    private var timer: Timer?
    private let key = "blockedBundleIDs"

    init() {
        blocked = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        Monitor.shared = self
        status = blocker.canEnforce
            ? "pf enforcement active"
            : "read-only: run ./run.sh --install once to enforce blocks"
    }

    /// Called from the view, not init: publishing while the view graph is
    /// building the model aborts with an AttributeGraph cycle. The first tick
    /// gets its own runloop turn for the same reason — `.task` still runs
    /// inside the update pass that laid the view out.
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        DispatchQueue.main.async { [weak self] in self?.tick() }
    }

    func isBlocked(_ app: AppRow) -> Bool { blocked.contains(app.id) }

    func setBlocked(_ app: AppRow, _ off: Bool) {
        if off { blocked.insert(app.id) } else { blocked.remove(app.id) }
        UserDefaults.standard.set(Array(blocked), forKey: key)
        Task { @MainActor in self.tick() }
    }

    func flush() {
        blocker.flush { [weak self] in self?.status = $0 }
    }

    // MARK: - polling

    private func refreshApps() {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
        apps = running.map {
            AppRow(id: $0.bundleIdentifier ?? "pid:\($0.processIdentifier)",
                   name: $0.localizedName ?? "unknown",
                   pid: $0.processIdentifier,
                   icon: $0.icon)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func tick() {
        refreshApps()
        // Unprivileged lsof sees only this user's processes, which is every app
        // in the list; a blocked app's root-owned helper is missed.
        let (_, lsofOut) = run("/usr/sbin/lsof", ["-nP", "-i", "-F", "pcfnPT"])
        let (_, psOut) = run("/bin/ps", ["-axo", "pid=,ppid="])
        let owner = ownerMap(psOut: psOut)

        var hosts: Set<String> = []
        for c in parseLsof(lsofOut) where c.direction != .listen {
            guard let id = owner[c.pid], blocked.contains(id), let host = c.remoteHost else { continue }
            hosts.insert(host)
        }

        blocker.apply(hosts: hosts) { [weak self] in self?.status = $0 }
    }

    /// pid -> app id, walking parents so helper processes (renderers, network
    /// services) land under the app that spawned them. A helper reparented to
    /// launchd shows under its own process name instead.
    private func ownerMap(psOut: String) -> [Int32: String] {
        var parent: [Int32: Int32] = [:]
        for line in psOut.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            if f.count >= 2, let p = Int32(f[0]), let pp = Int32(f[1]) { parent[p] = pp }
        }
        var appOf: [Int32: String] = [:]
        for a in apps { appOf[a.pid] = a.id }
        var out: [Int32: String] = appOf
        for pid in parent.keys where out[pid] == nil {
            var cur = pid
            var chain: [Int32] = []
            var hops = 0
            while cur > 1, hops < 12 {
                if let id = appOf[cur] {
                    for c in chain { out[c] = id }
                    break
                }
                chain.append(cur)
                guard let next = parent[cur], next != cur else { break }
                cur = next
                hops += 1
            }
        }
        return out
    }
}
