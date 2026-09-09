# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Unplug is a macOS SwiftUI app: the Force Quit running-apps list with a network on/off switch per app. Blocking is enforced with pf. `README.md` holds the user-facing description and the honest limits of the approach — read it before changing anything about blocking.

## Commands

```sh
./run.sh                          # build release, self-check, install the pfctl rule, launch
./run.sh --install                # same, installed to /Applications instead of .build/
./run.sh --uninstall              # remove /etc/sudoers.d/unplug and any loaded rules
swift build                       # debug build
swift build -c release
$(swift build -c release --show-bin-path)/unplug --self-check   # the whole test suite
sudo -k -n pfctl -a com.apple/unplug -s rules                   # is the passwordless rule live?
sudo pfctl -a com.apple/unplug -F rules                         # clear rules a killed process left loaded
```

`.build/` was copied from another checkout at some point; a stale
`ModuleCache` there fails the build with `missing required module 'SwiftShims'`.
`rm -rf .build` fixes it.

There is no test target and no XCTest. `--self-check` (`selfCheck()` in `Parse.swift`) is it: preconditions over a hardcoded `lsof -F` sample plus the pf rule strings. `run.sh` runs it on every build, so a broken parser fails the build. Add cases there rather than introducing a test framework.

## Architecture

Four files, no dependencies, one SPM executable target, macOS 14+.

- `main.swift` — entry point, the SwiftUI views, `NSApplication` and window set up by hand (no `@main` App, no bundle resources).
- `Monitor.swift` — the `@MainActor` model. Owns the 1.5 s poll, the app list, the blocked set, and the pid→app attribution.
- `Blocker.swift` — pf. Also `run(_:_:input:)`, the process helper used everywhere.
- `Parse.swift` — `lsof -F` field parsing and `selfCheck()`. Pure, no I/O.

**The loop.** `Monitor.tick()` every 1.5 s: refresh `NSWorkspace.runningApplications` filtered to `.regular` (that filter is what makes the list match Force Quit) → `lsof -nP -i -F pcfnPT` + `ps -axo pid=,ppid=` → `ownerMap` walks parent pids so helper processes (renderers, network services) attribute to the app that spawned them → collect remote addresses of blocked apps → `Blocker.apply` writes them as `block drop quick` rules into the `com.apple/unplug` pf sub-anchor.

**Why the sub-anchor.** Stock `/etc/pf.conf` already has `anchor "com.apple/*"`, so loading into `com.apple/unplug` needs no edit to any system file. pf is enabled with the refcounted `pfctl -E` and released with `-X <token>` on flush.

**Privilege.** The app runs as the ordinary user; only `pfctl` needs root. Every pfctl call goes through the free `pfctl(_:)` function in `Blocker.swift`, which execs directly when already root and otherwise via `sudo -n`. `run.sh` installs `/etc/sudoers.d/unplug` once, allowlisting the exact argument forms that function produces — so **adding or changing a pfctl invocation means updating the `Cmnd_Alias` in `run.sh` too**, or it silently falls back to read-only. `Blocker.canEnforce` probes this once at startup with `-s rules`; when false, switches only record intent and the status line says so.

**Cleanup** happens in `applicationWillTerminate` via the `Monitor.shared` weak static. Closing the window terminates the app, which is what releases pf.

## Constraints worth knowing before editing

- pf matches packets, not processes: a block is by remote address and hits every app talking to that address, and an address is only known after the first connection to it. `Blocker` is deliberately the single swap point for a real `NEFilterDataProvider` system extension — keep it that way, and keep the ceiling documented in its doc comment.
- `Monitor.start()` must be called from the view's `.task`, not `init`, and its first `tick()` takes its own runloop turn. Publishing while the view graph builds the model aborts with an AttributeGraph cycle.
- The window's SwiftUI root goes in via `window.contentViewController = NSHostingController(...)`. A bare `NSHostingView` as `contentView` aborts with `AttributeGraph: cycle detected` (SIGABRT, exit 134) the moment the list lays out — the view sizes itself from the window that is sizing itself from the view.
- **That abort only reproduces inside a real `.app` bundle.** The bare `swift build` binary runs the same code happily for as long as you leave it. So a UI change is only tested once it is in a bundle: `./run.sh --install`, then run `/Applications/Unplug.app/Contents/MacOS/Unplug` — several times, since the cycle is timing-sensitive. A SIGABRT leaves an `.ips` in `~/Library/Logs/DiagnosticReports/`; read its triggered thread rather than guessing at the cause.
- `pfctl -f` calls a missing final newline a syntax error, and always warns about ALTQ on macOS — `Blocker.apply` filters the warnings to find real errors.
- New pf rules do not touch sockets pf already has state for, hence the `pfctl -k` kill of live connections for newly added hosts.
- Blocked apps persist in `UserDefaults` under `blockedBundleIDs`, keyed by bundle id (or `pid:<n>` when an app has none, which does not survive a restart).
- `pfRulesPath` is `~/.unplug/pf.rules`, `0700` dir — not `/tmp`, where anyone could plant the ruleset the allowlisted pfctl then loads. The path is duplicated in `run.sh` (`RULES`) because sudoers must name it literally; keep the two in sync, and keep it free of spaces, which sudoers command paths handle badly.
- Unprivileged `lsof` only lists this user's processes. That covers every app in the list, but not a blocked app's root-owned helper.
- IPv6 needs `inet6` in the rule and `[::1]:port` bracket handling in `Conn.host(of:)`.

Comments in this codebase name the ceiling of a deliberate shortcut and its upgrade path. Match that; don't add comments restating what the code says.
