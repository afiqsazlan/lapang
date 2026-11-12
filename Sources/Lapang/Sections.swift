import Foundation

// Custom sections: any executable that prints JSON when run with no arguments, and handles
// the `run` arguments of its own buttons and menu items. See README.md for the format.

struct SectionOutput: Decodable {
    var badge: Badge?
    var rows: [SectionRow] = []

    enum CodingKeys: String, CodingKey { case badge, rows }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        badge = try c.decodeIfPresent(Badge.self, forKey: .badge)
        rows = try c.decodeIfPresent([SectionRow].self, forKey: .rows) ?? []
    }
}

struct Badge: Decodable, Hashable {
    let text: String
    let tone: String?  // good | warn | bad | info | (none = neutral)
}

struct SectionRow: Decodable, Identifiable {
    let title: String
    let subtitle: String?
    let icon: String?
    let tags: [Badge]?
    /// Rows sharing a group are folded into a disclosure list under that name.
    let group: String?
    let link: String?
    let reveal: String?
    let button: SectionAction?
    let menu: SectionMenu?
    var id: String { [group ?? "", title, subtitle ?? ""].joined(separator: "\u{1F}") }
}

struct SectionAction: Decodable {
    let title: String
    let run: [String]
    /// When set, Lapang asks first; this is the dialog's explanation.
    let confirm: String?
}

struct SectionMenu: Decodable {
    let title: String
    let items: [SectionMenuItem]
}

struct SectionMenuItem: Decodable, Identifiable {
    let title: String
    let checked: Bool?
    let run: [String]
    let confirm: String?
    var id: String { title }
}

struct SectionState: Identifiable {
    let config: SectionConfig
    let output: SectionOutput?
    let error: String?
    var id: String { config.id }
}

enum Sections {
    static func run(_ configs: [SectionConfig]) -> [SectionState] {
        configs.map { cfg in
            let exe = Paths.expand(cfg.command)
            guard FileManager.default.isExecutableFile(atPath: exe) else {
                return SectionState(config: cfg, output: nil, error: "Not executable: \(Paths.abbreviate(exe))")
            }
            guard let r = Shell.run(exe, []) else {
                return SectionState(config: cfg, output: nil, error: "Couldn't start \(Paths.abbreviate(exe))")
            }
            guard r.status == 0 else {
                let why = r.errText.split(separator: "\n").last.map(String.init) ?? "exit \(r.status)"
                return SectionState(config: cfg, output: nil, error: why)
            }
            do {
                return SectionState(config: cfg, output: try JSONDecoder().decode(SectionOutput.self, from: r.out), error: nil)
            } catch {
                return SectionState(config: cfg, output: nil, error: "Output isn't valid section JSON: \(error.localizedDescription)")
            }
        }
    }

    /// Runs one of a section's actions; returns the first line it printed, for the status line.
    static func perform(_ cfg: SectionConfig, _ args: [String], label: String? = nil) -> String? {
        let r = Shell.run(Paths.expand(cfg.command), args, env: ["LAPANG_CONFIRMED": "1"])
        let text = r.map { $0.status == 0 ? $0.text : ($0.errText.isEmpty ? $0.text : $0.errText) } ?? ""
        let first = text.split(separator: "\n").first.map(String.init)
        let result: String? = switch r?.status {
        case nil: "couldn't start \(Paths.abbreviate(Paths.expand(cfg.command)))"
        case 0: nil
        case let code?: "exit \(code)" + (first.map { ": " + $0 } ?? "")
        }
        ActionLog.record("section action", title: [cfg.title, label].compactMap { $0 }.joined(separator: ": "),
                         target: ["section": cfg.title, "command": cfg.command, "label": label ?? "",
                                  "args": args.joined(separator: " "), "output": first ?? ""],
                         result: result)
        guard r != nil else { return "Couldn't run \(cfg.title)" }
        return first
    }
}
