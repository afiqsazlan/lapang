import Foundation

/// Sample data for `Headroom --render out.png --demo`, used for the README screenshot,
/// so nothing from the machine it runs on ends up in a published image.
enum Demo {
    static func snapshot() -> Snapshot {
        let now = Date()
        let home = "/Users/me"
        let root = home + "/Library/Developer/Xcode/DerivedData"
        let gb: (Double) -> Int64 = { Int64($0 * 1_048_576) }  // GB -> KB

        // A week of free space: slow decline, a cleanup 22 hours ago, filling since
        var history: [HistoryPoint] = []
        for i in stride(from: 7 * 288, through: 0, by: -1) {
            let hoursAgo = Double(i) * 5 / 60
            let wobble = sin(Double(i) / 9) * 0.4
            let free = hoursAgo > 22 ? 21 + (hoursAgo - 22) * 0.2 + wobble : 52 - (22 - hoursAgo) * 0.6 + wobble * 0.5
            history.append(HistoryPoint(t: now.addingTimeInterval(-hoursAgo * 3600), freeGB: free))
        }
        let freeGB = history.last!.freeGB

        func entry(_ name: String, _ workspace: String, _ status: DerivedEntry.Status, _ idle: Int) -> DerivedEntry {
            DerivedEntry(name: name, path: root + "/" + name, workspace: workspace,
                         lastBuilt: now.addingTimeInterval(-Double(idle) * 86400), status: status, idleDays: idle)
        }
        let derived = [
            entry("Runner-akq", home + "/code/shop/ios/Runner.xcworkspace", .protected, 0),
            entry("Runner-bxe", home + "/code/worktrees/checkout-redesign/shop/ios/Runner.xcworkspace", .live, 0),
            entry("Runner-cmt", home + "/code/worktrees/search-filters/shop/ios/Runner.xcworkspace", .live, 5),
            entry("Runner-dvp", home + "/code/worktrees/old-onboarding/shop/ios/Runner.xcworkspace", .orphan, 9),
            entry("Weather-fzr", home + "/code/weather/Weather.xcodeproj", .live, 1),
        ]
        let caches = [
            CacheInfo(id: "pub", name: "pub", path: home + "/.pub-cache", clearable: false, note: "shared by every Dart project, kept"),
            CacheInfo(id: "npm", name: "npm", path: home + "/.npm", clearable: true, note: nil),
            CacheInfo(id: "gradle", name: "Gradle", path: home + "/.gradle/caches", clearable: true, note: nil),
            CacheInfo(id: "yarn", name: "Yarn", path: home + "/Library/Caches/Yarn", clearable: true, note: nil),
            CacheInfo(id: "cocoapods", name: "CocoaPods", path: home + "/Library/Caches/CocoaPods", clearable: true, note: nil),
        ]
        SizeStore.shared.useDemo([
            root: gb(10.8),
            derived[0].path: gb(3.9), derived[1].path: gb(2.9), derived[2].path: gb(1.8),
            derived[3].path: gb(1.6), derived[4].path: gb(0.6),
            caches[0].path: gb(3.8), caches[1].path: gb(2.4), caches[2].path: gb(1.3),
            caches[3].path: gb(1.1), caches[4].path: gb(0.6),
        ])

        let started: (Double) -> Date = { now.addingTimeInterval(-$0 * 60) }
        let procs = [
            DevProc(pid: 4821, ppid: 4790, name: "dart", kind: "mcp", rssBytes: 60 << 20, started: started(95),
                    cwd: home + "/code", stale: false),
            DevProc(pid: 4835, ppid: 4821, name: "dart", kind: "lsp", rssBytes: 410 << 20, started: started(95),
                    cwd: home + "/code", stale: false),
            DevProc(pid: 5120, ppid: 5101, name: "dartaotruntime", kind: "compiler", rssBytes: 380 << 20, started: started(42),
                    cwd: home + "/code/worktrees/checkout-redesign/shop", stale: false),
            DevProc(pid: 3377, ppid: 1, name: "dart", kind: "devtools", rssBytes: 95 << 20, started: started(1460),
                    cwd: home + "/code/worktrees/old-onboarding/shop", stale: true),
        ]

        let section = """
        {
          "badge": { "text": "2 running", "tone": "good" },
          "rows": [
            { "title": "api", "subtitle": "~/code/api [main] · :8080", "icon": "server.rack",
              "link": "http://localhost:8080", "button": { "title": "Restart", "run": ["restart", "api"] } },
            { "title": "web", "subtitle": "~/code/web [feature/cart] · :3000", "icon": "macwindow",
              "tags": [{ "text": "hot reload", "tone": "info" }], "link": "http://localhost:3000",
              "button": { "title": "Restart", "run": ["restart", "web"] } },
            { "title": "postgres 16", "subtitle": "port 5432", "icon": "cylinder", "group": "Databases" },
            { "title": "redis", "subtitle": "port 6379", "icon": "cylinder", "group": "Databases" }
          ]
        }
        """
        let output = try? JSONDecoder().decode(SectionOutput.self, from: Data(section.utf8))

        var config = Config()
        config.xcode.protect = ["~/code/shop"]
        return Snapshot(
            config: config, configError: nil,
            freeBytes: Int64(freeGB * 1_073_741_824), totalBytes: 460 * 1_073_741_824,
            pressure: 1, swapUsed: 2_200 << 20, swapTotal: 8_192 << 20,
            sims: [Sim(udid: "A", name: "iPhone 16 Pro"), Sim(udid: "B", name: "iPad Air 13-inch (M2)")],
            procs: procs,
            derivedDataRoot: root, derived: derived, caches: caches,
            history: history,
            trend: Trend.compute(history, freeGB: freeGB, warnGB: config.disk.warnGB),
            growth: Growth(
                since: now.addingTimeInterval(-24 * 3600),
                items: [
                    GrowthItem(name: "Xcode build caches", deltaKB: gb(5.2), detail: "new: checkout-redesign/shop +2.9 GB"),
                    GrowthItem(name: "npm", deltaKB: gb(1.1), detail: nil),
                    GrowthItem(name: "Homebrew", deltaKB: -gb(3.4), detail: nil),
                ],
                untrackedKB: gb(2.3)),
            sizesMeasuredAt: now.addingTimeInterval(-12 * 60),
            sections: [SectionState(config: SectionConfig(title: "Local servers", icon: "server.rack", command: ""),
                                    output: output, error: nil)]
        )
    }
}
