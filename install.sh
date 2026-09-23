#!/usr/bin/env bash
# curl -fsSL https://raw.githubusercontent.com/yama6a/airlock/main/install.sh | bash
set -euo pipefail

REPO=yama6a/airlock
INSTALL_DIR="$HOME/.airlock"
LINK=/usr/local/bin/airlock

log() { echo "airlock install: $*" >&2; }
die() {
  log "$*"
  exit 1
}

[[ "$(uname -s)" == Darwin ]] || die "macOS only"
command -v "${AIRLOCK_ENGINE:-docker}" > /dev/null || die "${AIRLOCK_ENGINE:-docker} not found on PATH"

mkdir -p "$INSTALL_DIR/bin" "$INSTALL_DIR/lib"
curl -fsSL -o "$INSTALL_DIR/bin/airlock" "https://raw.githubusercontent.com/$REPO/main/airlock"
curl -fsSL -o "$INSTALL_DIR/lib/seed.sh" "https://raw.githubusercontent.com/$REPO/main/lib/seed.sh"
chmod 0755 "$INSTALL_DIR/bin/airlock"
# Pulls the image and swaps these main-branch copies for the ones tagged with the image's version.
"$INSTALL_DIR/bin/airlock" --self-update

if [[ "$(readlink "$LINK" 2> /dev/null)" != "$INSTALL_DIR/bin/airlock" ]]; then
  log "linking $LINK, sudo may ask for your password"
  sudo mkdir -p "$(dirname "$LINK")"
  sudo ln -sfn "$INSTALL_DIR/bin/airlock" "$LINK"
fi
log "done, run: airlock"
