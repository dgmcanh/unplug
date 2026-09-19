#!/bin/sh
# Build and wrap in a .app bundle.
#   ./run.sh              build, self-check, install the pfctl rule, launch
#   ./run.sh --install    same build, installed to /Applications
#   ./run.sh --uninstall  remove the pfctl rule and any loaded pf rules
#
# Root is needed by pfctl and by nothing else, so instead of running the whole
# app as root on every launch we install one /etc/sudoers.d rule — one password,
# once — that lets this user run Unplug's own pfctl commands without a password.
set -e
cd "$(dirname "$0")"

SUDOERS=/etc/sudoers.d/unplug
RULES="$HOME/.unplug/pf.rules"      # must match pfRulesPath in Blocker.swift

# With no tty sudo cannot ask for a password at all, which is what happens when
# this runs from an editor, an agent, or a double-click. Hand it an askpass
# helper then, so the ask becomes the standard GUI password dialog.
SUDO=sudo
if [ ! -t 0 ]; then
  ASKPASS="$(mktemp -t unplug.askpass)"
  trap 'rm -f "$ASKPASS"' EXIT
  cat > "$ASKPASS" <<'ASK'
#!/bin/sh
osascript \
  -e 'display dialog "Unplug needs your password once, to install the pfctl rule that lets it load firewall rules without asking again." with title "Unplug" default answer "" with hidden answer' \
  -e 'text returned of result' 2>/dev/null
ASK
  chmod 700 "$ASKPASS"
  SUDO_ASKPASS="$ASKPASS"
  export SUDO_ASKPASS
  SUDO="sudo -A"
fi

if [ "$1" = "--uninstall" ]; then
  $SUDO /sbin/pfctl -a com.apple/unplug -F rules 2>/dev/null || true
  $SUDO rm -f "$SUDOERS"
  echo "removed $SUDOERS"
  exit 0
fi

swift build -c release
BIN="$(swift build -c release --show-bin-path)/unplug"
"$BIN" --self-check

case "$1" in
  --install) APP="/Applications/Unplug.app" ;;
  *)         APP=".build/Unplug.app" ;;
esac

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Unplug"
./icon.sh .build
cp .build/Unplug.icns "$APP/Contents/Resources/Unplug.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Unplug</string>
  <key>CFBundleDisplayName</key><string>Unplug</string>
  <key>CFBundleIdentifier</key><string>local.unplug</string>
  <key>CFBundleExecutable</key><string>Unplug</string>
  <key>CFBundleIconFile</key><string>Unplug</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "warning: ad-hoc codesign failed"

mkdir -p "$(dirname "$RULES")"
chmod 700 "$(dirname "$RULES")"

# Exact command forms only: this user may load rules from their own file into
# the com.apple/unplug anchor, kill states, and enable/release pf. Nothing else,
# and no other pfctl invocation, becomes passwordless.
TMP="$(mktemp -t unplug.sudoers)"
cat > "$TMP" <<EOF
# Installed by Unplug's run.sh. Remove with: ./run.sh --uninstall
Cmnd_Alias UNPLUG_PF = /sbin/pfctl -a com.apple/unplug -f $RULES, \\
                       /sbin/pfctl -a com.apple/unplug -F rules, \\
                       /sbin/pfctl -a com.apple/unplug -s rules, \\
                       /sbin/pfctl -E, \\
                       /sbin/pfctl -X *, \\
                       /sbin/pfctl -k * -k *
$(id -un) ALL=(root) NOPASSWD: UNPLUG_PF
EOF

# The rule is 0440 root:wheel, so we cannot read it back to compare — ask pf
# instead, with the sudo timestamp cleared so a cached password cannot fake a
# pass. A rule left over from a different $HOME still passes here; run
# --uninstall first if the rules path has moved.
if sudo -k -n /sbin/pfctl -a com.apple/unplug -s rules >/dev/null 2>&1; then
  echo "pfctl rule already installed"
else
  echo "installing $SUDOERS so pf rules load without a password — enter your password"
  # sudo ignores any file in sudoers.d whose name contains a dot, so the staged
  # copy is inert until visudo has approved it.
  $SUDO install -m 0440 -o root -g wheel "$TMP" "$SUDOERS.staged"
  if $SUDO visudo -cf "$SUDOERS.staged" >/dev/null; then
    $SUDO mv "$SUDOERS.staged" "$SUDOERS"
  else
    $SUDO rm -f "$SUDOERS.staged"
    echo "error: generated sudoers file is invalid, nothing installed" >&2
    exit 1
  fi
  # Same probe again, now as the check that the rule really took.
  if sudo -k -n /sbin/pfctl -a com.apple/unplug -s rules >/dev/null 2>&1; then
    echo "passwordless pfctl ok — no password needed on launch from now on"
  else
    echo "warning: passwordless pfctl still not working; the app will run read-only" >&2
  fi
fi
rm -f "$TMP"

if [ "$1" = "--install" ]; then
  echo "installed $APP"
  exit 0
fi

open "$APP"
