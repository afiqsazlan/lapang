# Headroom

A small macOS menu bar app that keeps an eye on what quietly fills up a developer's Mac, and lets you clear it in a click.

The menu bar shows free disk space (`41G`) and adds a warning sign when space is low or filling fast. The label is kept narrow on purpose: on a notched MacBook, menu bar items that don't fit are silently hidden. The panel shows:

- **Disk**: free space, a usage bar, and a chart for 24 hours or 7 days.
- **Trend**: how fast the disk is filling (a straight-line fit over the last 24 hours, restarting after any cleanup) and when it will reach your warning line, drawn as a dashed projection on the chart. A comparison with the size check from about a day ago shows what grew, e.g. `+4.2 GB Xcode build caches (mostly my-app +3.7 GB)`, with an "everything else" line for growth no measured folder explains. You get a notification when free space drops below your threshold, or when it's on course to within `forecastHours`.
- **Memory**: memory pressure and swap. macOS can't grow swap on a nearly full disk, so a full disk shows up as memory trouble too.
- **Simulators**: booted iOS simulators, each with a shut-down button.
- **Dev processes**: watched processes (Dart and Flutter by default) with memory use and uptime. A process is marked stale when its parent died or its folder is gone.
- **Xcode build caches**: one row per DerivedData folder, mapped back to its project. Each shows size and when it was last built, and whether the project still exists. You can clean orphaned or unused caches in bulk; projects you mark as protected are never touched.
- **Package caches**: npm, Yarn, pnpm, CocoaPods, Gradle, Homebrew, pub, iOS DeviceSupport and Xcode archives, with a Clear button where clearing is safe.
- **Custom sections**: anything else, from your own scripts (see below).

Destructive buttons always ask first. Folder sizes are measured in the background every 30 minutes, because `du` on big caches is slow.

## Build and run

Requires macOS 14 or later and Xcode (or the Command Line Tools with Swift 5.10+).

```bash
git clone https://github.com/afiqsazlan/headroom.git && cd headroom
./build.sh
```

`build.sh` compiles a release build, installs `Headroom.app` into `~/Applications` and launches it. To have it start at login, tick **Open at login** in the panel's gear menu. Use `./build.sh --no-install` to only build `./build/Headroom.app`.

## Configuration

Gear menu → **Edit config…** opens `~/.config/headroom/config.json`, creating it if needed. Every key is optional, and changes apply on the next refresh.

```json
{
  "refreshSeconds": 60,
  "disk": { "warnGB": 20, "criticalGB": 10, "notify": true, "forecastHours": 24, "watch": ["~/Downloads"] },
  "xcode": {
    "idleDays": 3,
    "protect": ["~/code/my-app"]
  },
  "processes": { "names": ["dart", "dartaotruntime"] },
  "caches": { "hide": ["pnpm"] },
  "sections": [
    { "title": "Servers", "icon": "server.rack", "command": "~/.config/headroom/sections/servers.sh" }
  ]
}
```

- `disk.forecastHours`: warn early when the fill rate says free space will reach `warnGB` within this many hours.
- `disk.watch`: extra folders to include in "what's growing". Xcode and package caches are always measured.
- `xcode.protect`: project folders whose build caches are never cleaned in bulk, usually your main checkouts. Rebuilding those from scratch is slow, while caches of throwaway worktrees aren't worth keeping.
- `processes.names`: executable names to watch.
- `caches.hide`: cache ids to leave out. The ids are `npm`, `yarn`, `pnpm`, `cocoapods`, `gradle`, `homebrew`, `pub`, `devicesupport` and `archives`.

## Custom sections

A section is any executable. When run with no arguments, it prints JSON:

```json
{
  "badge": { "text": "All up", "tone": "good" },
  "rows": [
    {
      "title": "api",
      "subtitle": "~/code/api [main]",
      "icon": "server.rack",
      "tags": [{ "text": "dirty", "tone": "warn" }],
      "link": "https://api.localhost",
      "reveal": "~/code/api",
      "button": { "title": "Restart", "run": ["restart", "api"], "confirm": "Drops open connections." },
      "menu": { "title": "Switch", "items": [{ "title": "main", "checked": true, "run": ["switch", "main"] }] }
    },
    { "title": "notes", "icon": "doc", "group": "Docs", "reveal": "~/notes" }
  ]
}
```

- `tone` is one of `good`, `warn`, `bad` or `info`, or leave it out for neutral.
- `icon` is any SF Symbol name.
- `link` adds an open-in-browser button. `reveal` makes the row show that path in Finder when clicked.
- Rows that share a `group` fold into a disclosure list.
- `button` and menu `items` run the same executable with their `run` arguments. If `confirm` is set, Headroom asks first and then sets `HEADROOM_CONFIRMED=1`. The first line the script prints is shown in the panel's status line.

The section runs on every refresh, so keep it fast (well under a second).

## Development

`Headroom --render out.png` draws the full panel off-screen with live data and exits. It's useful for checking layout without clicking around the menu bar.

## License

MIT, see [LICENSE](LICENSE).
