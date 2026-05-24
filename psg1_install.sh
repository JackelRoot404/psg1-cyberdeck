#!/usr/bin/env bash
# PSG1 install — sideload an APK onto a stock PSG1 from the jumpbox.
#
# The PSG1 bakes the `no_install_unknown_sources` restriction into user 0, so
# the on-device installer (F-Droid, Aurora, the package-installer UI) is gated
# with "Unknown apps can't be installed by this user". Clearing the restriction
# needs MANAGE_USERS (signature-level), which shell/Shizuku can't hold. The
# working channel is `pm install -i com.playsolana.echos`: spoofing Echos as
# the installer satisfies the gate. See PSG1_NOTES.md.
#
# Usage (run on the jumpbox that's ADB-connected to the PSG1):
#   ./psg1_install.sh <app.apk>                 # local file
#   ./psg1_install.sh https://f-droid.org/F-Droid.apk   # or a URL
#   ./psg1_install.sh <app.apk> <adb-serial>    # pick a device if several
#
# Split-APK / .xapk / .apks bundles: merge to a single universal APK first
# (APKEditor) and pass that — session-based split installs drop the -i
# attribution and the spoof fails. See PSG1_NOTES.md "For multi-APK apps".

set -euo pipefail

INSTALLER="com.playsolana.echos"
SRC="${1:?usage: psg1_install.sh <app.apk|url> [adb-serial]}"
SERIAL="${2:-}"

ADB=(adb)
[ -n "$SERIAL" ] && ADB=(adb -s "$SERIAL")

log() { printf '\033[1;36m[psg1-install]\033[0m %s\n' "$*"; }

# Resolve the source to a local file, downloading first if it's a URL.
TMP_LOCAL=""
cleanup() { [ -n "$TMP_LOCAL" ] && rm -f "$TMP_LOCAL"; }
trap cleanup EXIT

case "$SRC" in
  http://*|https://*)
    TMP_LOCAL="$(mktemp --suffix=.apk)"
    log "downloading $SRC"
    curl -fSL "$SRC" -o "$TMP_LOCAL"
    APK="$TMP_LOCAL"
    ;;
  *)
    [ -f "$SRC" ] || { echo "no such file: $SRC" >&2; exit 1; }
    APK="$SRC"
    ;;
esac

# A device has to be attached.
if ! "${ADB[@]}" get-state >/dev/null 2>&1; then
  echo "no device reachable — check 'adb devices'" >&2
  exit 1
fi

# Echos must stay installed for user 0 (even if disable-user'd) or the spoof
# fails with "Installer not allowed: null (uid=-1)".
if ! "${ADB[@]}" shell pm list packages --user 0 2>/dev/null | grep -q "package:${INSTALLER}\b"; then
  log "WARNING: $INSTALLER is not installed for user 0 — the spoof will fail."
  log "restore it with: ${ADB[*]} shell pm install-existing --user 0 $INSTALLER"
fi

REMOTE="/data/local/tmp/psg1-install-$$.apk"
log "pushing $(basename "$APK")"
"${ADB[@]}" push "$APK" "$REMOTE" >/dev/null

log "installing via -i $INSTALLER"
set +e
OUT="$("${ADB[@]}" shell pm install -r -i "$INSTALLER" "$REMOTE" 2>&1)"
RC=$?
set -e
"${ADB[@]}" shell rm -f "$REMOTE" >/dev/null 2>&1 || true

printf '%s\n' "$OUT"
if [ "$RC" -ne 0 ] || ! grep -qi success <<<"$OUT"; then
  if grep -qi 'Installer not allowed' <<<"$OUT"; then
    log "the Echos spoof broke — restore it with:"
    log "  ${ADB[*]} shell pm install-existing --user 0 $INSTALLER"
  fi
  echo "install failed" >&2
  exit 1
fi
log "done"
