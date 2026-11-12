import AppKit
import SwiftUI
import UserNotifications

// Sharing a card: render it to PNG, the "Share snapshot…" window (copy, save, share sheet),
// `lapang share`, and the optional Monday-morning weekly recap notification.

@MainActor
enum ShareRenderer {
    /// A PNG of the card, at 2x by default so it stays sharp after the site recompresses it.
    static func png(_ kind: ShareKind, ratio: ShareRatio, names: Bool, snapshot s: Snapshot, scale: CGFloat = 2,
                    src: ShareSources = .live) -> Data? {
        let view = ShareCardView(content: ShareContent.make(kind, s, names: names, src: src), m: CardMetrics(ratio: ratio))
        let r = ImageRenderer(content: view)
        r.scale = scale
        r.proposedSize = ProposedViewSize(ratio.size)
        guard let cg = r.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    static let folder: String = {
        let dir = Paths.support + "/shares"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func defaultPath(_ kind: ShareKind, _ ratio: ShareRatio) -> String {
        "\(folder)/lapang-\(kind.rawValue)-\(Daily.key(Date()))-\(ratio.label.replacingOccurrences(of: ":", with: "x")).png"
    }

    static func copy(_ png: Data) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let img = NSImage(data: png) { pb.writeObjects([img]) }
        pb.setData(png, forType: .png)
    }
}

// MARK: - Window

@MainActor
enum ShareWindow {
    private static var window: NSWindow?
    private static var model: ShareModel?

    static func show(_ m: Monitor, kind: ShareKind? = nil) {
        if window == nil {
            let model = ShareModel(monitor: m)
            let vc = NSHostingController(rootView: SharePanel(model: model))
            vc.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: vc)
            w.styleMask = [.titled, .closable]
            w.title = "Share snapshot"
            w.isReleasedWhenClosed = false
            w.center()
            window = w
            self.model = model
        }
        if let kind { model?.kind = kind } else { model?.pickDefault() }
        model?.render()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class ShareModel: ObservableObject {
    let monitor: Monitor
    @Published var kind: ShareKind = .today { didSet { if kind != oldValue { render() } } }
    @Published var ratio: ShareRatio = .portrait { didSet { if ratio != oldValue { render() } } }
    @Published var names = false { didSet { if names != oldValue { render() } } }
    @Published var preview: NSImage?
    @Published var file: URL?
    @Published var status: String?

    init(monitor: Monitor) { self.monitor = monitor }

    /// Right after a clean, open on the clean card.
    func pickDefault() {
        if let last = ActionLog.recent(1).first, Date().timeIntervalSince(last.time) < 1800, last.result == "ok" {
            kind = .clean
        }
    }

    func render() {
        guard let s = monitor.snap, let png = ShareRenderer.png(kind, ratio: ratio, names: names, snapshot: s) else { return }
        preview = NSImage(data: png)
        let url = URL(fileURLWithPath: ShareRenderer.defaultPath(kind, ratio))
        try? png.write(to: url)
        file = url
        status = nil
    }

    func copy() {
        guard let f = file, let d = try? Data(contentsOf: f) else { return }
        ShareRenderer.copy(d)
        status = "Copied"
    }

    func save() {
        guard let f = file else { return }
        let p = NSSavePanel()
        p.nameFieldStringValue = f.lastPathComponent
        p.allowedContentTypes = [.png]
        if p.runModal() == .OK, let dest = p.url {
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: f, to: dest)
            status = "Saved"
        }
    }
}

struct SharePanel: View {
    @ObservedObject var model: ShareModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $model.kind) {
                ForEach(ShareKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            HStack {
                Picker("", selection: $model.ratio) {
                    ForEach(ShareRatio.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                Spacer()
                Toggle("Show project names", isOn: $model.names)
                    .toggleStyle(.checkbox)
                    .help("Off: counts only. On: worktree/repo names (never full paths). Only the Today card uses them.")
            }
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .underPageBackgroundColor))
                if let img = model.preview {
                    Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                        .padding(14)
                        .onDrag { NSItemProvider(contentsOf: model.file) ?? NSItemProvider() }
                } else {
                    ProgressView()
                }
            }
            .frame(width: 520, height: 400)
            HStack {
                Text(model.status ?? "Drag the image out, or:").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Save…") { model.save() }
                if let f = model.file {
                    ShareLink(item: f) { Label("Share…", systemImage: "square.and.arrow.up") }
                }
                Button("Copy image") { model.copy() }.keyboardShortcut("c").buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 552)
    }
}

// MARK: - CLI

extension CLI {
    /// `lapang share [now|today|week|clean] [--ratio 4:5] [--out file.png] [--copy] [--names] [--scale 1] [--demo]`
    static func share(_ args: [String]) -> Int32 {
        var kind = ShareKind.today
        var ratio = ShareRatio.portrait
        var out: String?
        var scale: CGFloat = 2
        var i = 0
        while i < args.count {
            let a = args[i]
            func next() -> String? { i + 1 < args.count ? args[i + 1] : nil }
            switch a {
            case "--ratio":
                guard let v = next(), let r = ShareRatio.parse(v) else {
                    print("--ratio takes one of: " + ShareRatio.allCases.map { "\($0.rawValue) (\($0.label))" }.joined(separator: ", "))
                    return 2
                }
                ratio = r; i += 1
            case "--out":
                guard let v = next() else { print("--out takes a file path"); return 2 }
                out = v; i += 1
            case "--scale":
                guard let v = next(), let n = Double(v), n > 0, n <= 4 else { print("--scale takes 1 to 4"); return 2 }
                scale = n; i += 1
            case "--copy", "--names", "--demo": break
            default:
                guard let k = ShareKind(rawValue: a) else {
                    print("Unknown card \"\(a)\". Cards: " + ShareKind.allCases.map(\.rawValue).joined(separator: ", "))
                    return 2
                }
                kind = k
            }
            i += 1
        }
        let demo = args.contains("--demo")
        let s = demo ? Demo.snapshot() : snapshot()
        let png = MainActor.assumeIsolated {
            ShareRenderer.png(kind, ratio: ratio, names: args.contains("--names"), snapshot: s, scale: scale,
                              src: demo ? .demo(s) : .live)
        }
        guard let png else { print("Couldn't render the card."); return 1 }
        let path = out.map { Paths.expand($0) } ?? MainActor.assumeIsolated { ShareRenderer.defaultPath(kind, ratio) }
        do { try png.write(to: URL(fileURLWithPath: path)) } catch { print("Couldn't write \(path): \(error.localizedDescription)"); return 1 }
        if args.contains("--copy") { MainActor.assumeIsolated { ShareRenderer.copy(png) } }
        print(path)
        return 0
    }
}

// MARK: - Weekly recap

@MainActor
enum WeeklyRecap {
    static let key = "weeklyRecapLastNotified"
    static let identifier = "weekly-recap"

    /// Monday from 09:00, once a week, when `share.weeklyRecap` is on.
    static func maybeNotify(_ s: Snapshot) {
        guard s.config.share.weeklyRecap else { return }
        let cal = Calendar.current
        let now = Date()
        guard cal.component(.weekday, from: now) == 2, cal.component(.hour, from: now) >= 9 else { return }
        let week = "\(cal.component(.yearForWeekOfYear, from: now))-\(cal.component(.weekOfYear, from: now))"
        guard UserDefaults.standard.string(forKey: key) != week else { return }
        UserDefaults.standard.set(week, forKey: key)
        let w = ShareContent.week(s)
        let c = UNMutableNotificationContent()
        c.title = "Your week on this Mac"
        c.body = w.headline + " Click to share the recap."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: c, trigger: nil))
    }
}
