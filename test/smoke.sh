#!/usr/bin/env bash
# Everything checkable without a container runtime. CI runs this on macos-latest for bash 3.2.
set -uo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1
ROOT="$(pwd -P)"
FIX="$HOME/.airlock-smoke"                        # under $HOME: only $HOME, /Users, /Volumes pass
STUB="$FIX/stub"
fails=0

ok()   { printf '  ok    %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }
head_() { printf '\n%s\n' "$*"; }

trap 'rm -rf "$FIX"' EXIT

# Linux CI and Linux contributors would otherwise stop at the platform guard.
mkdir -p "$STUB"
printf '#!/bin/sh\n[ "$1" = -s ] && echo Darwin || exec /usr/bin/uname "$@"\n' > "$STUB/uname"
printf '#!/bin/sh\nexit 1\n' > "$STUB/noengine"
chmod 0755 "$STUB/uname" "$STUB/noengine"
BIN="$STUB:/usr/bin:/bin"

# Stock macOS PATH and no inherited environment, which is how the launcher must survive.
airlock() {
  env -i PATH="$BIN" HOME="$HOME" AIRLOCK_ENGINE=noengine /bin/bash "$ROOT/airlock" "$@" 2>&1
}

expect_die() {
  local want="$1"; shift
  local out; out="$(airlock "$@")"
  case "$out" in
    *"$want"*) ok "$* -> $want" ;;
    *) bad "$* -> expected '$want', got: $(printf '%s' "$out" | head -1)" ;;
  esac
}

head_ "syntax"
for f in airlock lib/seed.sh entrypoint.sh test/smoke.sh; do
  if /bin/bash -n "$f" 2>/dev/null; then ok "$f parses"; else bad "$f does not parse"; fi
done

head_ "platform guard"
# pipefail would report the launcher's own exit status, not grep's, so capture first.
guard="$(env -i PATH=/usr/bin:/bin HOME="$HOME" /bin/bash "$ROOT/airlock" --help 2>&1)"
case "$guard" in
  *"macOS only"*)   ok "dies on a non-Darwin uname" ;;
  *"usage: airlock"*) ok "host is Darwin, guard lets it through" ;;
  *) bad "guard: $(printf '%s' "$guard" | head -1)" ;;
esac

head_ "--help"
help="$(airlock --help)"
case "$help" in *'usage: airlock'*) ok "prints usage" ;; *) bad "no usage" ;; esac
for flag in --config --build --shell --no-yolo --add-dir-rw --add-dir-ro --reset; do
  case "$help" in *"$flag"*) ok "documents $flag" ;; *) bad "$flag undocumented" ;; esac
done

head_ "--env"
expect_die "is not a variable name" --env "1BAD=x"
expect_die "is not a variable name" --env "a-b=x"
expect_die "needs NAME=value"      --env
out="$(airlock --env AIRLOCK_SMOKE_UNSET)"
case "$out" in *"unset on the host, skipped"*) ok "bare --env of an unset var skips" ;;
  *) bad "bare --env: $(printf '%s' "$out" | head -1)" ;; esac

head_ "--add-dir"
mkdir -p "$FIX/repo"
expect_die "not a directory"          --add-dir "$FIX/does-not-exist"
expect_die "refusing /"               --add-dir /
expect_die "refusing \$HOME"          --add-dir "$HOME"
expect_die "collides with the config" --add-dir "$HOME/.claude"
expect_die "outside the paths"        --add-dir /etc
expect_die "needs a directory"        --add-dir-ro
out="$(airlock --add-dir-rw "$FIX/repo" --add-dir-ro "$FIX/repo")"
case "$out" in *"cannot reach noengine"*) ok "valid dirs get past parsing" ;;
  *) bad "valid dirs: $(printf '%s' "$out" | head -1)" ;; esac

head_ "seed detection and copy"
if ! tar --no-mac-metadata -cf /dev/null -C "$FIX" . 2>/dev/null; then
  echo "  skip  this tar has no --no-mac-metadata, so it is not the bsdtar airlock targets"
  head_ "result"
  [[ "$fails" == 0 ]] && echo "  all checks passed (seed copy skipped)" || echo "  $fails failed"
  exit $((fails > 0))
fi

# The layout that breaks naive implementations: symlinks into a flat dir, plus a dangling one.
mkdir -p "$FIX/flat/skills/a" "$FIX/dot"
printf '{"statusLine":{"command":"%s/flat/status.sh"}}' "$FIX" > "$FIX/flat/settings.json"
printf '#!/bin/sh\necho hi\n' > "$FIX/flat/status.sh"; chmod 0755 "$FIX/flat/status.sh"
printf '# md\n' > "$FIX/flat/CLAUDE.md"
printf 'x\n' > "$FIX/flat/skills/a/SKILL.md"
printf '{"mcpServers":{"one":{"command":"npx"}},"userID":"must-not-travel"}' > "$FIX/dot/.claude.json"
for n in settings.json CLAUDE.md skills; do ln -s "$FIX/flat/$n" "$FIX/dot/$n"; done
ln -s "$FIX/flat/gone" "$FIX/dot/hooks"            # top level: never offered at all
ln -s "$FIX/flat/gone" "$FIX/flat/skills/a/broken" # nested under a symlinked dir: must be excluded

printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "$DUMP_ARGS"\ncat > "$DUMP_TAR"\n' > "$STUB/dumpengine"
chmod 0755 "$STUB/dumpengine"

seed_out="$(
  exec 2>&1                                        # log() and die() write to stderr
  export PATH="$BIN" DUMP_TAR="$FIX/stream.tar" DUMP_ARGS="$FIX/args.txt"
  cd "$ROOT" || exit 1
  log() { echo "airlock: $*" >&2; }
  die() { log "$*"; exit 1; }
  HOST_CLAUDE="$FIX/dot" HOST_CLAUDE_JSON="$FIX/dot/.claude.json"
  CONFIG_FILE="$FIX/prefs" VOLUME=smoke BOX_CLAUDE="$HOME/.claude" ENGINE=dumpengine IMAGE=smoke
  MOUNT_GIT=0 MOUNT_KUBE=0 MOUNT_SSH=0 MOUNT_DOCKER_SOCK=0
  . lib/seed.sh
  CONFIG_FILE="$FIX/prefs"; seed_load_prefs; CONFIG_FILE="$FIX/prefs"
  HOST_CLAUDE="$FIX/dot"; HOST_CLAUDE_JSON="$FIX/dot/.claude.json"
  seed_detect
  for ((i = 0; i < ${#i_name[@]}; i++)); do
    [[ "${i_kind[$i]}" == mount ]] || i_on[$i]=1     # everything copyable, including MCP
  done
  seed_apply
)"

case "$seed_out" in *"dangling symlink skills/a/broken"*) ok "nested dangling link excluded" ;;
  *) bad "nested dangling link not excluded" ;; esac
case "$seed_out" in *"dangling symlink hooks"*) bad "top-level dangling link was offered" ;;
  *) ok "top-level dangling link not offered" ;; esac

if [[ -s "$FIX/stream.tar" ]]; then
  mkdir -p "$FIX/x" && tar -xf "$FIX/stream.tar" -C "$FIX/x" 2>/dev/null
  for want in settings.json CLAUDE.md skills/a/SKILL.md host-scripts/status.sh .mcp-seed.json; do
    [[ -e "$FIX/x/$want" ]] && ok "copied $want" || bad "missing $want"
  done
  [[ -z "$(find "$FIX/x" -type l)" ]] && ok "no symlinks survived" || bad "a symlink survived"
  [[ -e "$FIX/x/skills/a/broken" ]] && bad "the broken link was copied" || ok "broken link left out"
  grep -q '"one"' "$FIX/x/.mcp-seed.json" && ok "mcpServers carried" || bad "mcpServers missing"
  grep -q 'must-not-travel' "$FIX/x/.mcp-seed.json" \
    && bad "the rest of .claude.json leaked" || ok "only mcpServers copied"
  grep -q 'SED_EXPRS=.*host-scripts/status.sh' "$FIX/args.txt" \
    && ok "statusLine path rewritten" || bad "statusLine path not rewritten"
else
  bad "no tar stream produced"
fi

grep -q 'mcpServers' "$FIX/prefs" && ok "answers saved" || bad "answers not saved"

head_ "result"
if [[ "$fails" == 0 ]]; then echo "  all checks passed"; else echo "  $fails failed"; fi
exit $((fails > 0))
