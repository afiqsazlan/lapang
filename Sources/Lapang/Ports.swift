import Darwin
import Foundation

// Which of your programs are listening on a TCP port, read from the kernel with libproc (no lsof).
// Only a socket in LISTEN state makes a process a server here: a program that merely has a
// connection to a port (a tunnel, a browser, a proxy) is never listed as its owner, so it can
// never be the one that gets stopped.

struct Listener: Identifiable {
    let pid: pid_t
    let ppid: pid_t
    let exe: String
    let name: String
    /// What it is, from the executable and its arguments: "Vite", "Next.js", "php artisan serve", "redis"…
    let kind: String
    var ports: [UInt16]
    /// "localhost", "all interfaces", or the one address it's bound to.
    var exposure: String
    let started: Date
    let startSec: UInt64
    let cwd: String
    let bytes: UInt64
    /// It was started in a folder that has since been deleted (a removed worktree, say).
    var folderGone = false
    /// Your own name for the port, from `ports.names` in config.json.
    var label: String? = nil
    /// Port forwards owned by Docker or OrbStack: stopping the backend would stop every container.
    var stopNote: String? = nil

    var id: pid_t { pid }
    var port: UInt16 { ports[0] }
    var portList: String { ports.map(String.init).joined(separator: ", ") }
    var stoppable: Bool { stopNote == nil }
    var isTunnel: Bool { ["cloudflared", "ngrok"].contains(kind) }
    var isHTTP: Bool { !Ports.notHTTP.contains(kind) }
    var url: String? { isHTTP ? "http://localhost:\(port)" : nil }


    /// The last two folders of where it was started, which tell worktrees apart. Left out when the
    /// folder says nothing (/, your home folder, a service's data folder under ~/Library or Homebrew).
    var folder: String? {
        guard !cwd.isEmpty, cwd != "/", cwd != Paths.home else { return nil }
        if !folderGone {
            for p in [Paths.home + "/Library/", "/opt/homebrew", "/usr/local", "/Library/", "/private/var/"]
            where cwd.hasPrefix(p) { return nil }
        }
        return cwd.split(separator: "/").suffix(2).joined(separator: "/")
    }

    var uptime: String {
        let s = Int(Date().timeIntervalSince(started))
        if s >= 86400 { return "\(s / 86400)d \(s % 86400 / 3600)h" }
        if s >= 3600 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        return "\(max(s, 0) / 60)m"
    }

    var title: String { "\(portList) · \(kind)" }

    var subtitle: String {
        var parts: [String] = []
        if kind == "cloudflared" { parts.append("tunnel metrics") }
        if let f = folder { parts.append(f) }
        parts += ["up \(uptime)", human(bytes: Int64(bytes))]
        return parts.joined(separator: " · ")
    }

    var tags: [String] {
        var t: [String] = []
        if let label { t.append(label) }
        if exposure != "localhost" { t.append(exposure) }
        if folderGone { t.append("folder gone") }
        return t
    }

    var help: String {
        var lines = ["\(name) (pid \(pid))", exe]
        if !cwd.isEmpty { lines.append("Started in \(Paths.abbreviate(cwd))\(folderGone ? " (deleted)" : "")") }
        if let stopNote { lines.append(stopNote) }
        return lines.joined(separator: "\n")
    }
}

enum Ports {
    static let notHTTP: Set<String> = ["postgres", "mysqld", "redis", "mongodb", "memcached", "adb", "Docker", "OrbStack"]

    /// Your listening servers, filtered by `ports` in config.json.
    static func discover(_ cfg: Config.Ports) -> [Listener] {
        all().compactMap { l -> Listener? in
            var l = l
            l.ports = l.ports.filter { p in
                Int(p) >= cfg.minPort && Int(p) <= cfg.maxPort && !cfg.hide.contains { $0.matches(port: p) }
            }
            guard !l.ports.isEmpty, !cfg.hide.contains(where: { $0.matches(listener: l) }) else { return nil }
            l.label = l.ports.lazy.compactMap { cfg.names[String($0)] }.first
            return l
        }
        .sorted { $0.port < $1.port }
    }

    /// Every listening process of yours, on any port, leaving out system services and app helpers
    /// (AirPlay, Raycast, editor helpers…): those aren't dev servers and Lapang won't stop them.
    static func all() -> [Listener] {
        let uid = getuid()
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var out: [Listener] = []
        for pid in pids.prefix(Int(max(n, 0))) where pid > 0 {
            var bsd = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
                  bsd.pbi_uid == uid, let exe = Engine.execPath(pid) else { continue }
            let container = containerApp(exe)
            guard container != nil || !isSystemOrAppHelper(exe) else { continue }
            let socks = listening(pid)
            guard !socks.isEmpty else { continue }
            out.append(make(pid: pid, exe: exe, bsd: bsd, socks: socks, container: container))
        }
        // workers forked by a server (nginx, php-fpm, gunicorn) share its socket: show the parent only
        return out.filter { w in
            !out.contains { $0.pid == w.ppid && !Set($0.ports).isDisjoint(with: w.ports) }
        }
    }

    /// The listener with this pid, if it is still the same program and still listening on `port`.
    static func current(_ l: Listener, port: UInt16) -> Listener? {
        var bsd = proc_bsdinfo()
        guard proc_pidinfo(l.pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
              bsd.pbi_start_tvsec == l.startSec, Engine.execPath(l.pid) == l.exe else { return nil }
        let socks = listening(l.pid)
        guard socks.contains(where: { $0.port == port }) else { return nil }
        return make(pid: l.pid, exe: l.exe, bsd: bsd, socks: socks, container: containerApp(l.exe))
    }

    private static func make(pid: pid_t, exe: String, bsd: proc_bsdinfo, socks: [Socket], container: String?) -> Listener {
        let name = (exe as NSString).lastPathComponent
        var task = proc_taskinfo()
        _ = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size))
        let cwd = Engine.currentDir(pid) ?? ""
        let exposed = socks.filter { !$0.loopback }
        let exposure: String = exposed.isEmpty ? "localhost"
            : exposed.contains(where: \.wildcard) ? "all interfaces" : exposed[0].address
        return Listener(
            pid: pid, ppid: pid_t(bsd.pbi_ppid), exe: exe, name: name, kind: container ?? kind(name: name, args: Engine.args(pid)),
            ports: Array(Set(socks.map(\.port))).sorted(), exposure: exposure,
            started: Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec)), startSec: bsd.pbi_start_tvsec,
            cwd: cwd, bytes: MemoryProbe.footprint(pid) ?? task.pti_resident_size,
            folderGone: !cwd.isEmpty && cwd != "/" && !FileManager.default.fileExists(atPath: cwd),
            stopNote: container.map { "A \($0) port forward. Stop the container instead; stopping \($0) stops all of them." })
    }

    static func isSystemOrAppHelper(_ path: String) -> Bool {
        for p in ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"] where path.hasPrefix(p) { return true }
        guard let r = path.range(of: ".app/Contents/") else { return false }
        // an interpreter shipped as an app inside a framework (Python.framework's Python.app) is a dev tool
        if path[..<r.lowerBound].contains(".framework/") { return false }
        let rest = path[r.upperBound...]
        return ["MacOS/", "Frameworks/", "XPCServices/", "Library/", "Helpers/", "PlugIns/", "Resources/", "SharedSupport/"]
            .contains { rest.hasPrefix($0) }
    }

    /// Docker and OrbStack own the host side of published container ports. Shown, never stopped.
    private static func containerApp(_ path: String) -> String? {
        if path.contains("/Docker.app/") || path.hasSuffix("/com.docker.backend") { return "Docker" }
        if path.contains("/OrbStack.app/") { return "OrbStack" }
        return nil
    }

    static func kind(name: String, args: [String]) -> String {
        let a = args.dropFirst().joined(separator: " ").lowercased()
        let n = name.lowercased()
        func has(_ s: String) -> Bool { a.contains(s) }
        switch n {
        case "node", "bun", "deno":
            if has("vite") { return "Vite" }
            if has("/next/") || has("next-server") || has("next dev") { return "Next.js" }
            if has("nuxt") { return "Nuxt" }
            if has("astro") { return "Astro" }
            if has("storybook") { return "Storybook" }
            if has("remix") { return "Remix" }
            if has("@angular") || has("ng serve") { return "Angular" }
            if has("expo") { return "Expo" }
            if has("metro") || has("react-native") { return "Metro" }
            if has("webpack") { return "webpack" }
            if has("wrangler") { return "Wrangler" }
            return n
        case "php":
            if has("artisan serve") || has("server.php") { return "php artisan serve" }
            if has("-s ") { return "php -S" }
            return "php"
        case "ruby":
            if has("rails") { return "Rails" }
            if has("puma") { return "Puma" }
            return "ruby"
        case "dart", "dartvm", "dartaotruntime":
            if has("flutter_tools") { return "flutter" }
            if has("development-service") || has("devtools") { return "Dart DevTools" }
            return "dart"
        case "redis-server": return "redis"
        case "mongod": return "mongodb"
        case "beam.smp": return "Elixir"
        default:
            if n.hasPrefix("php-fpm") { return "php-fpm" }
            if n.hasPrefix("python") {
                if has("http.server") { return "python http.server" }
                if has("runserver") { return "Django" }
                for f in ["uvicorn", "gunicorn", "flask", "jupyter", "mkdocs", "streamlit"] where has(f) { return f }
                return "python"
            }
            if n.hasPrefix("postgres") { return "postgres" }
            return name
        }
    }

    // MARK: Sockets, via proc_pidfdinfo

    struct Socket {
        let port: UInt16
        let address: String
        let wildcard: Bool
        let loopback: Bool
    }

    /// The TCP sockets in LISTEN state among this process's file descriptors.
    static func listening(_ pid: pid_t) -> [Socket] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard got > 0 else { return [] }
        var out: [Socket] = []
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { continue }
            let ini = tcp.tcpsi_ini
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport))
            if ini.insi_vflag & UInt8(INI_IPV6) != 0 {
                var a6 = ini.insi_laddr.ina_6
                let raw = withUnsafeBytes(of: &a6) { Array($0) }
                let any = raw.allSatisfy { $0 == 0 }
                let loop = raw.prefix(15).allSatisfy { $0 == 0 } && raw[15] == 1
                var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                inet_ntop(AF_INET6, &a6, &buf, socklen_t(buf.count))
                out.append(Socket(port: port, address: String(cString: buf), wildcard: any, loopback: loop))
            } else {
                var a4 = ini.insi_laddr.ina_46.i46a_addr4
                let host = UInt32(bigEndian: a4.s_addr)
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &a4, &buf, socklen_t(buf.count))
                out.append(Socket(port: port, address: String(cString: buf), wildcard: host == 0, loopback: host >> 24 == 127))
            }
        }
        return out
    }
}

enum PortActions {
    static func confirm(_ l: Listener) -> Monitor.Confirm {
        .init(title: "Stop \(l.kind) on port \(l.portList)?", message: message(l), button: "Stop")
    }

    static func message(_ l: Listener) -> String {
        var m = "Sends SIGTERM to \(l.name) (pid \(l.pid))"
        if !l.cwd.isEmpty { m += " in \(Paths.abbreviate(l.cwd))" }
        m += ". Only the process listening on the port is stopped. Anything connected to it, like a tunnel or a browser, is left alone."
        if l.isTunnel { m += "\n\nThis is a tunnel: every URL served through it goes down until you start it again." }
        return m
    }

    /// SIGTERM to the process that owns the LISTEN socket, after re-checking it is still the same
    /// program (same path and start time) still listening on that port. Never anything else.
    static func stop(_ l: Listener) -> String {
        let port = l.port
        func log(_ result: String?, freed: UInt64? = nil) {
            ActionLog.record("stop port", title: "\(l.kind) on port \(port)",
                             target: ["port": "\(port)", "pid": "\(l.pid)", "name": l.name, "kind": l.kind,
                                      "exe": l.exe, "folder": l.cwd, "folderGone": "\(l.folderGone)",
                                      "exposure": l.exposure, "label": l.label ?? ""],
                             result: result, memoryFreed: freed.map(Int64.init))
        }
        if let note = l.stopNote { log("refused: \(l.kind) port forward"); return note }
        guard getuid() == uid(of: l.pid) else {
            log("refused: another user's process")
            return "Port \(port) is held by another user's process; not stopped"
        }
        guard let now = Ports.current(l, port: port) else {
            let taken = Ports.all().contains { $0.ports.contains(port) }
            log(taken ? "port now held by another program" : "already gone")
            return taken ? "Port \(port) is now held by another program; nothing stopped"
                : "\(l.kind) on port \(port) had already stopped"
        }
        guard Darwin.kill(l.pid, SIGTERM) == 0 else {
            log(String(cString: strerror(errno)))
            return "Couldn't stop \(l.kind) (pid \(l.pid))"
        }
        for _ in 0 ..< 15 {
            usleep(200_000)
            if Ports.current(l, port: port) == nil {
                log(nil, freed: now.bytes)
                return "Stopped \(l.kind) on port \(port)"
            }
        }
        log("SIGTERM sent; port still open")
        return "Sent \(l.kind) (pid \(l.pid)) SIGTERM; port \(port) is still open"
    }

    private static func uid(of pid: pid_t) -> uid_t? {
        var bsd = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return nil }
        return bsd.pbi_uid
    }
}
