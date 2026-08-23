#!/usr/bin/env bash
# Resolves the container identity, seeds host material, then drops privileges.
set -euo pipefail

log() { echo "airlock: $*" >&2; }
die() { log "$*"; exit 1; }

USER_NAME="${AIRLOCK_USER:-dev}"
HOME_DIR="${AIRLOCK_HOME:-/home/$USER_NAME}"
HOST_HOME="${AIRLOCK_HOST_HOME:-$HOME_DIR}"
WORKDIR="${AIRLOCK_WORKDIR:-$PWD}"
CONFIG_DIR="$HOME_DIR/.claude"
SEED_DIR=/mnt/seed

# Bind-mount ownership varies by runtime, so read it rather than trusting the host's id.
TARGET_UID=""
TARGET_GID=""
if [[ -d "$WORKDIR" ]]; then
  probe_uid="$(stat -c %u "$WORKDIR" 2>/dev/null || true)"
  probe_gid="$(stat -c %g "$WORKDIR" 2>/dev/null || true)"
  if [[ -n "$probe_uid" && "$probe_uid" != "0" ]] && gosu "$probe_uid" test -w "$WORKDIR"; then
    TARGET_UID="$probe_uid"                       # writable, so the files are really ours
    TARGET_GID="$probe_gid"
  fi
fi
if [[ -z "$TARGET_UID" && -n "${AIRLOCK_HOST_UID:-}" && "$AIRLOCK_HOST_UID" != "0" ]]; then
  TARGET_UID="$AIRLOCK_HOST_UID"
  TARGET_GID="${AIRLOCK_HOST_GID:-$AIRLOCK_HOST_UID}"
fi
TARGET_UID="${TARGET_UID:-1000}"
TARGET_GID="${TARGET_GID:-$TARGET_UID}"

[[ "$TARGET_UID" == "0" ]] && die "refusing uid 0; --dangerously-skip-permissions requires non-root"
[[ "$TARGET_UID" -lt 100 ]] && die "refusing uid $TARGET_UID; it overlaps the system range"

replace() { cat "$1" > "$2" && rm -f "$1"; }      # keeps the target's inode and mode

# useradd rejects uids above UID_MAX, so write the databases directly.
group_name="$(awk -F: -v g="$TARGET_GID" '$3 == g { print $1; exit }' /etc/group)"
if [[ -z "$group_name" ]]; then
  group_name="$USER_NAME"
  awk -F: -v n="$USER_NAME" '$1 != n' /etc/group > /tmp/g && replace /tmp/g /etc/group
  printf '%s:x:%s:\n' "$USER_NAME" "$TARGET_GID" >> /etc/group
fi

awk -F: -v n="$USER_NAME" -v u="$TARGET_UID" '$1 != n && $3 != u' /etc/passwd > /tmp/p
replace /tmp/p /etc/passwd
printf '%s:x:%s:%s::%s:/bin/bash\n' \
  "$USER_NAME" "$TARGET_UID" "$TARGET_GID" "$HOME_DIR" >> /etc/passwd

add_to_group() {
  awk -F: -v g="$1" -v u="$USER_NAME" 'BEGIN { OFS=":" }
    $1 == g {
      n = split($4, m, ",")
      for (i = 1; i <= n; i++) if (m[i] == u) { print; next }
      $4 = ($4 == "" ? u : $4 "," u)
    }
    { print }
  ' /etc/group > /tmp/g && replace /tmp/g /etc/group
}

if [[ -S /var/run/docker.sock ]]; then
  sock_gid="$(stat -c %g /var/run/docker.sock)"   # differs per runtime
  if [[ "$sock_gid" != "0" ]]; then
    awk -F: -v g="$sock_gid" '$3 == g { found = 1 } END { exit !found }' /etc/group \
      || printf 'dockerhost:x:%s:\n' "$sock_gid" >> /etc/group
    add_to_group "$(awk -F: -v g="$sock_gid" '$3 == g { print $1; exit }' /etc/group)"
  fi
fi

# chown fails on an sshfs or 9p bind mount, so only image and volume paths can rely on it.
own() { chown "$TARGET_UID:$TARGET_GID" "$@" 2>/dev/null || true; }

mkdir -p "$HOME_DIR" "$CONFIG_DIR" "$HOME_DIR/go/bin" "$HOME_DIR/.docker" "$HOME_DIR/.cache"
own "$HOME_DIR" "$HOME_DIR/go" "$HOME_DIR/go/bin" "$HOME_DIR/.docker" "$HOME_DIR/.cache"

# The seed runs before the uid is known, so its files can land owned by someone else.
if [[ "$(stat -c %u "$CONFIG_DIR" 2>/dev/null || echo 0)" != "$TARGET_UID" ]]; then
  chown -R "$TARGET_UID:$TARGET_GID" "$CONFIG_DIR" 2>/dev/null || own "$CONFIG_DIR"
fi

# Copied, not bound, so writes stay off the host and ssh gets a writable known_hosts.
if [[ -d "$SEED_DIR/ssh" ]]; then
  rm -rf "$HOME_DIR/.ssh"
  cp -a "$SEED_DIR/ssh" "$HOME_DIR/.ssh"
  chown -R "$TARGET_UID:$TARGET_GID" "$HOME_DIR/.ssh"
  find "$HOME_DIR/.ssh" -type d -exec chmod 0700 {} +
  find "$HOME_DIR/.ssh" -type f -exec chmod 0600 {} +
fi

seed_file() {
  [[ -f "$SEED_DIR/$1" ]] || return 0
  install -D -o "$TARGET_UID" -g "$TARGET_GID" -m "${3:-0644}" \
    "$SEED_DIR/$1" "$HOME_DIR/$2"
}
seed_file gitconfig           .gitconfig
seed_file gitignore           .gitignore
seed_file git_allowed_signers .git_allowed_signers

if [[ "${AIRLOCK_COPY_KUBECONFIG:-1}" != 0 ]]; then
  seed_file kube-config .kube/config 0600
elif [[ -f "$SEED_DIR/kube-config" ]]; then
  log "AIRLOCK_COPY_KUBECONFIG=0, kubeconfig not copied"
fi

gitcfg="$HOME_DIR/.gitconfig"
gitc() { git -C / config -f "$gitcfg" "$@"; }
[[ -f "$gitcfg" ]] || { : > "$gitcfg"; own "$gitcfg"; }

# Runtimes that pass the host uid through trip git's dubious-ownership check.
gitc --replace-all safe.directory "$WORKDIR" 2>/dev/null || true
while IFS= read -r d; do
  [[ -n "$d" ]] || continue
  gitc --add safe.directory "$d" 2>/dev/null || true
done <<< "${AIRLOCK_ADD_DIRS:-}"

# ssh-keygen reads passphrases from /dev/tty even with stdin redirected, so force askpass.
nopass() { SSH_ASKPASS=/bin/false SSH_ASKPASS_REQUIRE=force DISPLAY='' "$@" </dev/null; }

pubkey_fingerprint() {
  nopass ssh-keygen -yf "$1" 2>/dev/null \
    | ssh-keygen -lf /dev/stdin 2>/dev/null | awk '{print $2}' || true
}

# No runtime forwards ssh-agent in, so a literal ssh signingkey must point at a key file.
if [[ "${AIRLOCK_FIX_SIGNING:-1}" != 0 ]]; then
  signkey="$(gitc --get user.signingkey 2>/dev/null || true)"
  if [[ "$signkey" == ssh-* || "$signkey" == ecdsa-* || "$signkey" == sk-* ]]; then
    pub="$(mktemp)"; printf '%s\n' "$signkey" > "$pub"
    want="$(ssh-keygen -lf "$pub" 2>/dev/null | awk '{print $2}' || true)"
    rm -f "$pub"
    found=""
    if [[ -n "$want" ]]; then
      for k in "$HOME_DIR"/.ssh/*; do
        [[ -f "$k" ]] || continue
        case "$k" in *.pub) continue ;; esac
        head -1 "$k" 2>/dev/null | grep -q 'PRIVATE KEY' || continue
        got="$(pubkey_fingerprint "$k")"          # empty when encrypted, so it is skipped
        if [[ -n "$got" && "$got" == "$want" ]]; then found="$k"; break; fi
      done
    fi
    if [[ -n "$found" ]]; then
      if [[ ! -f "${found}.pub" ]]; then          # ssh-keygen wants a <key>.pub sidecar
        nopass ssh-keygen -yf "$found" > "${found}.pub" 2>/dev/null \
          && own "${found}.pub" && chmod 0644 "${found}.pub"
      fi
      gitc user.signingkey "$found"
    else
      gitc commit.gpgsign false
      log "no usable private key matches user.signingkey; commit signing disabled here"
    fi
  fi
fi

# Generated, not copied: the host file's other keys are identity and caches.
claude_json="$CONFIG_DIR/.claude.json"
mcp_seed="$CONFIG_DIR/.mcp-seed.json"
if [[ ! -f "$claude_json" ]]; then
  base='{"hasCompletedOnboarding":true,"autoUpdates":false}'
  # Only on creation, so a `claude mcp add` in here is not undone on the next start.
  if [[ -f "$mcp_seed" ]] && jq -e . "$mcp_seed" >/dev/null 2>&1; then
    jq -n --argjson base "$base" --slurpfile mcp "$mcp_seed" '$base + $mcp[0]' > "$claude_json"
  else
    printf '%s\n' "$base" > "$claude_json"
  fi
  own "$claude_json"
  chmod 0600 "$claude_json"
fi

if [[ "$HOME_DIR" != "$HOST_HOME" && -f "$CONFIG_DIR/settings.json" ]]; then
  sed -i "s|$HOST_HOME|$HOME_DIR|g" "$CONFIG_DIR/settings.json"
  log "rewrote $HOST_HOME to $HOME_DIR in settings.json"
fi

# A command that was not copied in fails on every render, blaming itself and not the copy.
if [[ -f "$CONFIG_DIR/settings.json" ]]; then
  missing="$(jq -r '
    [(.statusLine.command // empty),
     (.hooks // {} | to_entries[].value[]?.hooks[]?.command // empty)]
    | map(split(" ")[0]) | .[]
  ' "$CONFIG_DIR/settings.json" 2>/dev/null \
    | while read -r c; do
        case "$c" in
          /*) [[ -e "$c" ]] || printf '%s ' "$c" ;;
        esac
      done)"
  [[ -n "$missing" ]] && log "settings.json references paths absent here: $missing"
fi

export HOME="$HOME_DIR"
export CLAUDE_CONFIG_DIR="$CONFIG_DIR"
export PATH="$HOME_DIR/go/bin:$PATH"

# Into the cache volume: npm and go default outside ~/.cache, so --rm would discard them.
export NPM_CONFIG_CACHE="$HOME_DIR/.cache/npm"
export GOMODCACHE="$HOME_DIR/.cache/go-mod"

exec gosu "$USER_NAME" "$@"
