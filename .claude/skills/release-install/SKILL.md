---
name: release-install
description: Build Unplug in release mode and install it to /Applications on this machine. Use when asked to install, reinstall, or ship the app locally, or to update /Applications/Unplug.app after a change.
---

# release-install

`run.sh --install` already does the whole thing — release build, `--self-check`, `.app` wrapper, ad-hoc codesign, install to `/Applications/Unplug.app`, and the `/etc/sudoers.d/unplug` rule that makes pf enforcement work without a password on every later launch. Run it, don't reimplement it.

```sh
./run.sh --install
```

It replaces any existing `/Applications/Unplug.app` and it does not launch the app.

**It needs the user's password** for the sudoers install (`/Applications` is group-writable by `admin`, so that part needs nothing) — unless `sudo -n true` already succeeds, meaning either a cached timestamp or the rule already being in place.

With no tty the script falls back to a `SUDO_ASKPASS` helper and asks in a native macOS dialog, so it works from a non-terminal context; it just needs someone at the keyboard. If running it is not permitted here, tell the user to run `! ./run.sh --install` themselves and report the output back.

If the build fails with `missing required module 'SwiftShims'`, `.build` was copied from another checkout: `rm -rf .build` and retry.

## Report back

- `installed /Applications/Unplug.app`.
- Whether the last line is `passwordless pfctl ok` or the `warning: passwordless pfctl still not working` — the second means the app will run read-only, and the sudoers rule is what to look at.
- `pfctl rule already installed` is the normal line on a reinstall, not a problem.
- `warning: ad-hoc codesign failed` — the app still runs, but Gatekeeper may complain.
- A failed `--self-check` means the build is broken; say which precondition tripped and stop, nothing was installed.

Launching is the user's call, not this skill's — plain `open /Applications/Unplug.app`, no root.
