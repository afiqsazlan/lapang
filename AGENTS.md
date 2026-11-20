# Lapang — agent notes

A macOS menu bar app (SwiftUI, SwiftPM) that watches what fills up a developer's Mac and clears it. The app binary is also the `lapang` CLI and an MCP server (`lapang mcp`). The README is the user-facing spec; read the section for whatever you're changing.

## Public package: build for everyone

Lapang is published (GitHub, Homebrew tap, notarized releases), so every change must make sense on a stranger's Mac.

- No person- or company-specific names, paths, hostnames, domains, ports or workflows in `Sources/`, the README or the defaults. The only exceptions are the project's own URLs: the repo, its issues page and the update feed.
- When a request comes from one setup ("show my dev URLs", "know about my worktree helper"), find the general mechanism and make it configurable: a config key, a `{placeholder}` command like `worktrees.removeCommand`, or a field in the custom section contract. If no general version makes sense, it belongs in the user's own files under `~/.config/lapang/` (config or a custom section script), not here.
- Defaults must be safe and neutral on a fresh install: nothing destructive without a confirm, and nothing that assumes a tool is installed without checking.
- Keep the privacy promises in the README: the Sparkle update check is the only network call, there is no telemetry, share cards and `lapang report` never show paths, user or host names. A new field that could carry those needs the same redaction.

## Layout

- `Sources/Lapang/*.swift`: engine (native: libproc, sysctl, `xcrun simctl` JSON, no `ps`/`lsof` shell-outs), views, CLI, MCP, sections.
- `Support/`: `Info.plist` (version), icon, `make-icon.swift`.
- `build.sh`: release build; `--no-install` builds `build/Lapang.app` only. `release.sh` + `RELEASING.md`: publishing.
- User data: `~/Library/Application Support/Lapang`; config: `~/.config/lapang/config.json`.

## Checking a change

```bash
./build.sh --no-install
build/Lapang.app/Contents/MacOS/Lapang --render out.png --demo     # panel, sample data
build/Lapang.app/Contents/MacOS/Lapang --render out.png --window     # window, live data
```

`screencapture` can't see menu bar items, so use `--render`. Try destructive actions against throwaway targets with `LAPANG_HOME=<folder>`. CLI actions are dry runs until `--yes`.

When behaviour or config changes, update the README section that describes it in the same change, and the demo data (`Demo.swift`, `ShareDemo.swift`) if the README screenshots would show it.

## Git and releases

- Commits carry no AI attribution trailer.
- Ask before pushing, and before running `release.sh` (it publishes the GitHub release, the appcast and the Homebrew cask).
