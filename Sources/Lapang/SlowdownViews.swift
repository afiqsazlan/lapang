import AppKit
import SwiftUI

// What slows a Mac down that pressure doesn't show: paging from swap, Spotlight indexing code
// folders, and MCP servers running many copies.

extension Snapshot {
    /// Paging worth a line of its own: thrashing, or the disk busy reading memory back in.
    var pagingShown: Paging? {
        guard let p = paging, p.thrashing || p.heavy else { return nil }
        return p
    }
}

/// "Paging 180 MB/s · 6.2k IOPS — mds_stores, Dart and Flutter, Xcode"
struct PagingLine: View {
    let p: Paging

    var body: some View {
        let names = p.topPagers.prefix(3).map(\.name).joined(separator: ", ")
        Text("Paging \(human(rate: p.pagingBytesPerSec)) · \(iopsText(p.iops)) IOPS" + (names.isEmpty ? "" : " — " + names))
            .font(.caption).foregroundStyle(p.thrashing ? Color.orange : Color.secondary)
            .lineLimit(1).truncationMode(.tail)
            .help(PagingLine.help(p))
    }

    static func help(_ p: Paging) -> String {
        var lines = [String(format: "Swap is %.0f%% full. ", p.swapFullShare * 100)
            + "The Mac is reading memory back from the disk, so apps wait on the disk even when pressure reads normal."]
        lines += p.topPagers.prefix(3).map { "\($0.name): \(human(rate: $0.bytesPerSecond))" }
        return lines.joined(separator: "\n")
    }
}

/// "Spotlight is indexing ~/Sites/shop (18 GB) and 3 more", with the folders and how to exclude them.
struct SpotlightHint: View {
    let s: Snapshot
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Text(Self.text(s)).font(.caption).foregroundStyle(.orange)
                .lineLimit(1).truncationMode(.middle)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            SpotlightFolders(s: s).padding(14).frame(width: 340)
        }
    }

    static func text(_ s: Snapshot) -> String {
        guard let f = s.spotlight?.folders, let first = f.first else {
            return "Spotlight is reading the disk hard. Checking which code folders it indexes…"
        }
        let more = f.count > 1 ? " and \(f.count - 1) more" : ""
        return "Spotlight is indexing \(Paths.abbreviate(first.path)) (\(human(kb: first.kb)))\(more)"
    }
}

/// The large code folders Spotlight indexes, each with a copyable command, and the Settings route.
struct SpotlightFolders: View {
    let s: Snapshot

    var body: some View {
        let folders = s.spotlight?.folders ?? []
        VStack(alignment: .leading, spacing: 8) {
            if s.spotlight?.indexingOff == true {
                Text("Spotlight indexing is off for this Mac.").font(.callout)
            } else if folders.isEmpty {
                Text(s.spotlight?.measuredAt == nil ? "Not checked yet." : "No large code folders are indexed.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(folders) { f in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Paths.abbreviate(f.path)).lineLimit(1).truncationMode(.middle)
                        Text("\(human(kb: f.kb)) · \(f.items.formatted()) items indexed")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(SpotlightReport.excludeCommand(f.path), forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help("Copy a command that excludes this folder: " + SpotlightReport.excludeCommand(f.path))
                }
            }
            if !folders.isEmpty {
                Text(SpotlightReport.howTo).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// MCP servers by command, when one runs in several copies: "6× dart mcp-server · 10.5 GB".
struct MCPFanoutRows: View {
    let groups: [MCPGroup]

    static func shown(_ s: Snapshot) -> [MCPGroup] {
        s.mcpGroups.contains { $0.pids.count > 1 || $0.orphaned > 0 } ? Array(s.mcpGroups.prefix(4)) : []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Caption(text: "MCP servers by command").padding(.top, 2)
            ForEach(groups) { g in
                ItemRow(title: "\(g.pids.count)× \(g.command)",
                        subtitle: Self.subtitle(g),
                        tags: g.orphaned > 0 ? ["\(g.orphaned) orphaned"] : [],
                        help: "pids " + g.pids.map(String.init).joined(separator: " ")) { _ in
                    Text(human(bytes: Int64(g.bytes))).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
    }

    static func subtitle(_ g: MCPGroup) -> String {
        "\(g.processes) process\(g.processes == 1 ? "" : "es"), with what they started"
    }
}

// MARK: - Window cards

struct PagingCard: View {
    let s: Snapshot
    let p: Paging

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Caption(text: "Paging, last second")
                Spacer()
                Text(String(format: "swap %.0f%% full", p.swapFullShare * 100))
                    .font(.caption).foregroundStyle(p.swapNearlyFull ? Color.orange : Color.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                stat(human(rate: p.pagingBytesPerSec), "read back from swap", p.thrashing)
                stat(iopsText(p.iops), "disk IOPS", false)
                stat(human(rate: p.diskBytesPerSec), "disk", false)
            }
            if !p.topPagers.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(p.topPagers.prefix(3).enumerated()), id: \.offset) { _, pager in
                        HStack {
                            Text(pager.name).lineLimit(1)
                            Spacer()
                            Text(human(rate: pager.bytesPerSecond)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
                .padding(.top, 2)
            }
            Footnote(text: p.thrashing
                     ? "Swap thrashing: swap is nearly full and the Mac keeps reading memory back from the disk, so everything waits on it. Quitting what pages most helps more than freeing RAM elsewhere."
                     : "Page-ins and disk operations over one second. Thrashing is when swap is nearly full and this stays high.")
        }
    }

    func stat(_ value: String, _ unit: String, _ warn: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(warn ? Color.orange : Color.primary)
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct MCPFanoutCard: View {
    let s: Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption(text: "MCP servers by command")
            if s.mcpGroups.isEmpty {
                Text("None running").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(s.mcpGroups.prefix(6)) { g in
                HStack(spacing: 6) {
                    Text("\(g.pids.count)× \(g.command)").lineLimit(1).truncationMode(.middle)
                    if g.orphaned > 0 { Tag(text: "\(g.orphaned) orphaned", color: .orange) }
                    Spacer()
                    Text(human(bytes: Int64(g.bytes))).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
                .help(MCPFanoutRows.subtitle(g))
            }
            Footnote(text: "Each copy's memory includes the language servers and other processes it started.")
        }
    }
}

struct SpotlightCard: View {
    @EnvironmentObject var m: Monitor
    let s: Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Caption(text: "Spotlight in code folders")
                Spacer()
                if m.checkingSpotlight {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Check now") { m.checkSpotlight(s.config) }.controlSize(.small)
                }
            }
            if s.paging?.spotlightPaging == true {
                Text("Spotlight is among the processes paging most.").font(.callout).foregroundStyle(.orange)
            }
            SpotlightFolders(s: s)
            if let t = s.spotlight?.measuredAt {
                Footnote(text: "Checked \(t.formatted(date: .omitted, time: .shortened)).")
            }
        }
    }
}
