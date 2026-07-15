#!/usr/bin/env bash
# Install (or refresh) the keepalive into a stable location outside the git tree.
#
# Why: cron runs one fixed path every 5 min. Pointing it into the working tree
# means the running keepalive silently follows whatever branch is checked out —
# check out an older branch to look at something and the deck quietly loses its
# fixes. A copy under ~/bin is what cron should run.
#
# The tradeoff is the copy going stale against the repo, so the installed file is
# stamped with the commit it came from, and --check reports drift.
#
#   ./psg1_keepalive_install.sh           # install or refresh
#   ./psg1_keepalive_install.sh --check   # in sync with the repo?
#   PSG1_KEEPALIVE_DEST=/opt/x.sh ./psg1_keepalive_install.sh
#
# A symlink would NOT do: it still resolves into the working tree, which is the
# problem being solved.

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SRC_DIR/psg1_keepalive.sh"
DEST="${PSG1_KEEPALIVE_DEST:-$HOME/bin/psg1_keepalive.sh}"
MARKER='^# INSTALLED'

log() { printf '\033[1;36m[keepalive-install]\033[0m %s\n' "$*"; }

[ -f "$SRC" ] || { echo "source not found: $SRC" >&2; exit 1; }

# The installed copy minus its stamp should be byte-identical to the repo file.
installed_body() { grep -v "$MARKER" "$DEST"; }

if [ "${1:-}" = "--check" ]; then
  if [ ! -f "$DEST" ]; then
    log "not installed at $DEST"
    exit 1
  fi
  grep -m1 '^# INSTALLED-FROM:' "$DEST" || log "(no provenance stamp — installed by hand?)"
  if diff -q <(installed_body) "$SRC" >/dev/null 2>&1; then
    log "in sync with $SRC"
    exit 0
  fi
  log "STALE — $DEST differs from the repo. Re-run without --check to refresh."
  diff <(installed_body) "$SRC" || true
  exit 1
fi

rev="$(git -C "$SRC_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
dirty=""
git -C "$SRC_DIR" diff --quiet -- psg1_keepalive.sh 2>/dev/null || dirty=" +uncommitted-edits"

mkdir -p "$(dirname "$DEST")"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# Stamp goes after the shebang so the file stays executable.
{
  head -1 "$SRC"
  echo "# INSTALLED COPY — do not edit here. Edit the repo and re-run psg1_keepalive_install.sh."
  echo "# INSTALLED-FROM: $SRC @ $rev$dirty on $(date '+%Y-%m-%d %H:%M:%S')"
  tail -n +2 "$SRC"
} > "$tmp"

bash -n "$tmp" || { echo "refusing to install: $SRC has a syntax error" >&2; exit 1; }

# Explicit mode: mktemp makes 0600, and `chmod +x` on top of that yields a weird
# 0711 (executable by others, readable by nobody).
chmod 0755 "$tmp"
mv "$tmp" "$DEST"
trap - EXIT

log "installed $DEST (from $rev$dirty)"
[ -n "$dirty" ] && log "NOTE: installed from uncommitted edits — commit them or the stamp lies about what's running."

cat <<EOF

Point cron at this copy (not the repo):

  PATH=/usr/local/bin:/usr/bin:/bin
  */5 * * * * PSG1_ADB_TARGETS="192.168.2.32:5555 100.64.30.85:5555" $DEST >>$HOME/psg1_keepalive.log 2>&1

After changing psg1_keepalive.sh in the repo, re-run this script or cron keeps
running the old copy. './psg1_keepalive_install.sh --check' reports drift.
EOF
