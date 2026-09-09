# Unplug

macOS app: the running-apps list from Force Quit, with a network on/off switch
per app.

```sh
./run.sh              # build, self-check, wrap in a .app, launch
./run.sh --install    # same build, installed to /Applications
./run.sh --uninstall  # give the passwordless pfctl rule back
```

## The password

Asked once, by the first `./run.sh`, and never again — not on later launches,
not after a reboot.

Root is needed by `pfctl` and by nothing else, so the app itself runs as you.
What the first run installs is `/etc/sudoers.d/unplug`, listing the exact pfctl
commands this app issues:

    /sbin/pfctl -a com.apple/unplug -f ~/.unplug/pf.rules
    /sbin/pfctl -a com.apple/unplug -F rules
    /sbin/pfctl -a com.apple/unplug -s rules
    /sbin/pfctl -E
    /sbin/pfctl -X *
    /sbin/pfctl -k * -k *

Those forms, run by your user, stop needing a password. What that grants is the
authority the app already has: loading rules from `~/.unplug/pf.rules` into one
pf anchor. It is not a general passwordless `sudo`, and `pfctl` cannot write
files or open a shell. Still, anything running as you can now change that file
and load it, so treat `~/.unplug/` as trusted — that is why it is `0700` in
your home and not in `/tmp`. `./run.sh --uninstall` takes the grant back.

Without the rule the app still runs: the switches only record intent, and the
status line says `read-only`. Launching it as root (`sudo …/Contents/MacOS/Unplug`)
also works and skips sudo entirely.

Doing this the way Little Snitch does — a signed privileged helper via
`SMAppService` — needs a Developer ID certificate and so does not work for a
locally built, ad-hoc signed app.

## How it works

- **App list** — `NSWorkspace.runningApplications` filtered to `.regular`
  activation policy, which is exactly what Force Quit shows.
- **Visibility** — unprivileged `lsof` sees only your own processes, which is
  every app in that list; a root-owned helper of a blocked app is missed.
- **Blocking** — polls `lsof -nP -i` every 1.5 s for the remote addresses a
  switched-off app is talking to, and loads pf rules for them into the
  `com.apple/unplug` sub-anchor, which the stock `/etc/pf.conf` already hooks
  via `anchor "com.apple/*"`, so no system file is edited. Connections from
  helper processes (renderers, network services) are attributed to the app
  that spawned them by walking parent pids. Rules are flushed and pf released
  on Quit.

## What blocking can and cannot do

pf matches packets, not processes. So:

- A block is by **remote address**, and it stops every app talking to that
  address, not only the one you switched off.
- An address is only known **after** the app has reached it once, so the first
  connection of a new address leaks; it is cut within one poll, and live
  states are killed with `pfctl -k`.

True per-app filtering needs a `NEFilterDataProvider` system extension and
Apple's networkextension entitlement (what Little Snitch and LuLu ship). The
`Blocker` type is the swap point for that.

Closing the window quits the app, which flushes the anchor. Killing the
process instead leaves the rules loaded — `sudo pfctl -a com.apple/unplug -F
rules` clears them.
