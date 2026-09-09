import Foundation

enum Direction: String {
    case out = "OUT"
    case incoming = "IN"
    case listen = "LISTEN"
}

struct Conn: Hashable {
    var pid: Int32
    var command: String
    var proto: String
    var local: String
    var remote: String
    var state: String
    var direction: Direction

    var key: String { "\(pid)|\(proto)|\(local)|\(remote)" }
    var remoteHost: String? {
        guard !remote.isEmpty else { return nil }
        return Conn.host(of: remote)
    }

    /// Splits "1.2.3.4:443" or "[::1]:443" into its host part.
    static func host(of endpoint: String) -> String? {
        if endpoint.hasPrefix("["), let close = endpoint.firstIndex(of: "]") {
            return String(endpoint[endpoint.index(after: endpoint.startIndex)..<close])
        }
        guard let colon = endpoint.lastIndex(of: ":") else { return nil }
        let h = String(endpoint[endpoint.startIndex..<colon])
        return h == "*" ? nil : h
    }

    static func port(of endpoint: String) -> String? {
        guard let colon = endpoint.lastIndex(of: ":") else { return nil }
        return String(endpoint[endpoint.index(after: colon)...])
    }
}

/// Parses `lsof -nP -i -F pcfnPT` field output.
func parseLsof(_ text: String) -> [Conn] {
    var conns: [Conn] = []
    var pid: Int32 = 0
    var command = ""
    var proto = ""
    var name = ""
    var state = ""
    var haveSocket = false

    func flush() {
        guard haveSocket, !name.isEmpty else { return }
        haveSocket = false
        let parts = name.components(separatedBy: "->")
        let local = parts[0]
        let remote = parts.count > 1 ? parts[1] : ""
        let dir: Direction = state == "LISTEN" || remote.isEmpty ? .listen : .out
        conns.append(Conn(pid: pid, command: command, proto: proto, local: local,
                          remote: remote, state: state, direction: dir))
        name = ""
        state = ""
    }

    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        guard let tag = line.first else { continue }
        let value = String(line.dropFirst())
        switch tag {
        case "p":
            flush()
            pid = Int32(value) ?? 0
        case "c":
            command = value
        case "f":
            flush()
            haveSocket = true
        case "P":
            proto = value
        case "n":
            name = value
        case "T":
            if value.hasPrefix("ST=") { state = String(value.dropFirst(3)) }
        default:
            break
        }
    }
    flush()

    // An established socket whose local port is also listened on by the same
    // process is an inbound connection. Cheap heuristic; a socket inherited
    // from another process is attributed to the holder, not the accepter.
    var listening: Set<String> = []
    for c in conns where c.direction == .listen {
        if let p = Conn.port(of: c.local) { listening.insert("\(c.pid):\(p)") }
    }
    for i in conns.indices where conns[i].direction == .out {
        if let p = Conn.port(of: conns[i].local), listening.contains("\(conns[i].pid):\(p)") {
            conns[i].direction = .incoming
        }
    }
    return conns
}

func selfCheck() -> Int32 {
    let sample = """
    p382
    crapportd
    f10
    PTCP
    n*:49152
    TST=LISTEN
    f11
    PTCP
    n127.0.0.1:49152->127.0.0.1:51000
    TST=ESTABLISHED
    p9000
    cSafari
    f5
    PTCP
    n192.168.1.5:52341->17.253.144.10:443
    TST=ESTABLISHED
    f6
    PUDP
    n[::1]:5353
    """
    let conns = parseLsof(sample)
    precondition(conns.count == 4, "expected 4 sockets, got \(conns.count)")
    precondition(conns[0].direction == .listen)
    precondition(conns[1].direction == .incoming, "local port 49152 is listened on by pid 382")
    precondition(conns[2].pid == 9000 && conns[2].command == "Safari")
    precondition(conns[2].direction == .out)
    precondition(conns[2].remoteHost == "17.253.144.10")
    precondition(conns[3].proto == "UDP" && conns[3].direction == .listen)
    precondition(Conn.host(of: "[::1]:5353") == "::1")
    precondition(Conn.host(of: "*:80") == nil)

    let rules = pfRules(hosts: ["17.253.144.10", "::1"])
    precondition(rules.contains("block drop quick from any to 17.253.144.10"), rules)
    precondition(rules.contains("block drop quick inet6 from any to ::1"), rules)
    precondition(pfRules(hosts: []).isEmpty)

    print("self-check ok")
    return 0
}
