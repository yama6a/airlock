# shellcheck shell=bash
# Detects host Claude config, asks what to copy, copies it in. Parallel arrays: no assoc in 3.2.

CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/airlock/config"

# name default kind
SEED_KNOWN="
settings.json:1:file
settings.local.json:0:file
CLAUDE.md:1:file
keybindings.json:1:file
statusline-command.sh:1:file
agents:1:dir
commands:1:dir
skills:1:dir
rules:1:dir
output-styles:1:dir
hooks:1:dir
themes:1:dir
workflows:1:dir
agent-memory:1:dir
plugins:1:dir
"

SEED_NEVER="credentials, the rest of .claude.json, projects/, history.jsonl, file-history/,
sessions/, shell-snapshots/, telemetry/, backups/, caches"

i_name=() i_label=() i_size=() i_on=() i_kind=() i_src=()

seed_load_prefs() {
  COPY_ITEMS="" MOUNT_GIT=1 MOUNT_KUBE=1 MOUNT_SSH=0 MOUNT_DOCKER_SOCK=0
  SEED_HAVE_PREFS=0
  if [[ -f "$CONFIG_FILE" ]]; then
    . "$CONFIG_FILE"
    SEED_HAVE_PREFS=1
  fi
}

seed_save_prefs() {
  mkdir -p "$(dirname "$CONFIG_FILE")"
  {
    echo "# written by airlock --config"
    echo "COPY_ITEMS=\"$1\""
    echo "MOUNT_GIT=$MOUNT_GIT"
    echo "MOUNT_KUBE=$MOUNT_KUBE"
    echo "MOUNT_SSH=$MOUNT_SSH"
    echo "MOUNT_DOCKER_SOCK=$MOUNT_DOCKER_SOCK"
  } > "$CONFIG_FILE"
}

# Apparent bytes: du reports disk blocks, so every small file would read as 4K.
seed_size() {
  find -L "$1" -type f -print0 2>/dev/null | xargs -0 wc -c 2>/dev/null \
    | awk '$2 != "total" { s += $1 } END {
        if (s >= 1048576) printf "%.1fM", s / 1048576
        else if (s >= 1024) printf "%.0fK", s / 1024
        else printf "%dB", s
      }'
}

seed_count() {
  local n
  n=$(find -L "$1" -type f 2>/dev/null | wc -l | tr -d ' ')
  [[ "$n" == 1 ]] && echo "1 file" || echo "$n files"
}

seed_in_list() {
  local needle="$1" hay="$2" x
  for x in $hay; do [[ "$x" == "$needle" ]] && return 0; done
  return 1
}

seed_add() {
  local n=${#i_name[@]}
  i_name[$n]="$1"; i_label[$n]="$2"; i_size[$n]="$3"
  i_on[$n]="$4"; i_kind[$n]="$5"; i_src[$n]="$6"
}

# Every settings key that can name an executable. The hooks walk covers all events.
SEED_CMD_JQ='
  [ (.statusLine.command // empty),
    (.apiKeyHelper // empty),
    (.awsAuthRefresh // empty),
    (.awsCredentialExport // empty),
    (.fileSuggestion // empty),
    (.otelHeadersHelper // empty),
    (.hooks // {} | to_entries[].value[]? | .hooks[]? | .command // empty) ]
  | map(split(" ")[0]) | unique | .[]
'

seed_detect() {
  i_name=(); i_label=(); i_size=(); i_on=(); i_kind=(); i_src=()
  local line name def kind path

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    name=${line%%:*}; line=${line#*:}
    def=${line%%:*}; kind=${line#*:}
    path="$HOST_CLAUDE/$name"
    [[ -e "$path" ]] || continue
    [[ "$SEED_HAVE_PREFS" == 1 ]] && { seed_in_list "$name" "$COPY_ITEMS" && def=1 || def=0; }
    if [[ "$kind" == dir ]]; then
      seed_add "$name" "$name/  $(seed_count "$path")" "$(seed_size "$path")" "$def" config "$path"
    else
      seed_add "$name" "$name" "$(seed_size "$path")" "$def" config "$path"
    fi
  done <<< "$SEED_KNOWN"

  seed_detect_scripts
  seed_detect_mcp
  seed_add git    ".gitconfig, .gitignore, allowed_signers" "" "$MOUNT_GIT"    mount git
  seed_add kube   ".kube/config"                            "" "$MOUNT_KUBE"   mount kube
  seed_add ssh    ".ssh  private keys"                      "" "$MOUNT_SSH"    mount ssh
  seed_add socket "docker socket  root on the host VM"      "" "$MOUNT_DOCKER_SOCK" mount socket
}

# These live outside ~/.claude, so the tar of the config dir would miss them.
seed_detect_scripts() {
  local settings="$HOST_CLAUDE/settings.json" cmd def
  [[ -f "$settings" ]] || return 0
  if ! command -v jq >/dev/null; then
    log "jq not found, so scripts referenced from settings.json are not detected"
    return 0
  fi
  while IFS= read -r cmd; do
    [[ "$cmd" == /* ]] || continue
    case "$cmd" in "$HOST_CLAUDE"/*) continue ;; esac
    [[ -f "$cmd" ]] || continue
    def=1
    [[ "$SEED_HAVE_PREFS" == 1 ]] && { seed_in_list "$cmd" "$COPY_ITEMS" && def=1 || def=0; }
    seed_add "$cmd" "$cmd" "$(seed_size "$cmd")" "$def" script "$cmd"
  done < <(jq -r "$SEED_CMD_JQ" "$settings" 2>/dev/null)
}

# The rest of .claude.json is identity and caches, so only this key is ever offered.
SEED_MCP_FILE=.mcp-seed.json

seed_detect_mcp() {
  local n def=0
  [[ -f "$HOST_CLAUDE_JSON" ]] || return 0
  command -v jq >/dev/null || return 0
  n=$(jq -r '.mcpServers // {} | length' "$HOST_CLAUDE_JSON" 2>/dev/null || echo 0)
  case "$n" in ''|*[!0-9]*) return 0 ;; esac
  [[ "$n" -gt 0 ]] || return 0
  [[ "$SEED_HAVE_PREFS" == 1 ]] && { seed_in_list mcpServers "$COPY_ITEMS" && def=1 || def=0; }
  seed_add mcpServers "MCP servers  $n, may hold API keys" "" "$def" mcp "$HOST_CLAUDE_JSON"
}

seed_render() {
  local n=${#i_name[@]} idx mark section=""
  echo
  echo "airlock: Claude config found in $HOST_CLAUDE"
  for ((idx = 0; idx < n; idx++)); do
    if [[ "${i_kind[$idx]}" != "$section" ]]; then
      section="${i_kind[$idx]}"
      case "$section" in
        config) echo; echo "  copy into the container volume" ;;
        script) echo; echo "  scripts your settings point at, copied alongside" ;;
        mcp)    echo; echo "  the only part of .claude.json that can be copied" ;;
        mount)  echo; echo "  mount from the host on every run" ;;
      esac
    fi
    [[ "${i_on[$idx]}" == 1 ]] && mark=x || mark=" "
    printf '  %2d [%s] %-44s %6s\n' "$((idx + 1))" "$mark" "${i_label[$idx]}" "${i_size[$idx]}"
  done
  echo
  echo "  never copied: $SEED_NEVER"
  echo
  echo "  number toggles, a=all, n=none, q=abort, Enter=accept"
}

seed_picker() {
  local reply tok n=${#i_name[@]} idx
  while :; do
    seed_render
    printf '> '
    read -r reply || reply=""
    case "$reply" in
      "") return 0 ;;
      a|A) for ((idx = 0; idx < n; idx++)); do i_on[$idx]=1; done ;;
      n|N) for ((idx = 0; idx < n; idx++)); do i_on[$idx]=0; done ;;
      q|Q) return 1 ;;
      *)
        for tok in $reply; do
          case "$tok" in
            ''|*[!0-9]*) log "not a number: $tok"; continue ;;
          esac
          idx=$((tok - 1))
          if [[ "$idx" -lt 0 || "$idx" -ge "$n" ]]; then
            log "out of range: $tok"
          elif [[ "${i_on[$idx]}" == 1 ]]; then i_on[$idx]=0
          else i_on[$idx]=1
          fi
        done ;;
    esac
  done
}

# bsdtar stores a dangling link as a link and exits 0 even under --dereference, so drop them.
# -L both descends into a symlinked config dir and leaves only broken links as -type l.
seed_dangling() {
  find -L "$@" -type l -print 2>/dev/null
}

seed_apply() {
  local n=${#i_name[@]} idx chosen="" tar_args=() scripts=() dang rel s stage="" mcp=0
  MOUNT_GIT=0 MOUNT_KUBE=0 MOUNT_SSH=0 MOUNT_DOCKER_SOCK=0

  local names=() drop=""
  for ((idx = 0; idx < n; idx++)); do
    if [[ "${i_on[$idx]}" != 1 ]]; then
      # Extraction only adds, so a deselected item would survive from an earlier run.
      [[ "${i_kind[$idx]}" == config ]] && drop="$drop ${i_name[$idx]}"
      [[ "${i_kind[$idx]}" == mcp ]] && drop="$drop $SEED_MCP_FILE"
      continue
    fi
    case "${i_kind[$idx]}" in
      config) names+=("${i_name[$idx]}"); chosen="$chosen ${i_name[$idx]}" ;;
      script) scripts+=("${i_src[$idx]}"); chosen="$chosen ${i_name[$idx]}" ;;
      mcp)    mcp=1; chosen="$chosen ${i_name[$idx]}" ;;
      mount)
        case "${i_name[$idx]}" in
          git) MOUNT_GIT=1 ;; kube) MOUNT_KUBE=1 ;;
          ssh) MOUNT_SSH=1 ;; socket) MOUNT_DOCKER_SOCK=1 ;;
        esac ;;
    esac
  done

  seed_save_prefs "${chosen# }"

  if [[ ${#names[@]} -eq 0 && ${#scripts[@]} -eq 0 && "$mcp" == 0 && -z "$drop" ]]; then
    log "nothing selected to copy"
    return 0
  fi

  if [[ ${#names[@]} -gt 0 ]]; then
    local abs=()
    for s in "${names[@]}"; do abs+=("$HOST_CLAUDE/$s"); done
    while IFS= read -r dang; do
      [[ -n "$dang" ]] || continue
      rel="${dang#"$HOST_CLAUDE"/}"
      log "skipping dangling symlink $rel"
      tar_args+=(--exclude "$rel")
    done < <(seed_dangling "${abs[@]}")
    tar_args+=(-C "$HOST_CLAUDE" "${names[@]}")
  fi

  # Another -C section, not a second tar: readers stop at the first archive's end marker.
  local sed_exprs=""
  if [[ ${#scripts[@]} -gt 0 || "$mcp" == 1 ]]; then
    stage=$(mktemp -d) || die "cannot create a staging dir"
  fi
  if [[ ${#scripts[@]} -gt 0 ]]; then
    mkdir -p "$stage/host-scripts"
    for s in "${scripts[@]}"; do
      install -m 0755 "$s" "$stage/host-scripts/" 2>/dev/null \
        || { log "cannot stage $s"; continue; }
      sed_exprs="$sed_exprs;s|$s|$BOX_CLAUDE/host-scripts/$(basename "$s")|g"
    done
    tar_args+=(-C "$stage" host-scripts)
  fi
  if [[ "$mcp" == 1 ]]; then
    if jq '{mcpServers}' "$HOST_CLAUDE_JSON" > "$stage/$SEED_MCP_FILE" 2>/dev/null; then
      chmod 0600 "$stage/$SEED_MCP_FILE"           # the definitions may hold API keys
      tar_args+=(-C "$stage" "$SEED_MCP_FILE")
    else
      log "cannot read mcpServers from $HOST_CLAUDE_JSON"
    fi
  fi

  log "seeding volume $VOLUME"
  # Never -L: to GNU tar that is --tape-length and it consumes an argument.
  COPYFILE_DISABLE=1 tar --dereference --no-mac-metadata --no-xattrs --no-fflags \
      -cf - "${tar_args[@]}" \
    | "$ENGINE" run --rm -i \
        --mount "type=volume,src=$VOLUME,dst=/seed" \
        -e "SED_EXPRS=${sed_exprs#;}" \
        -e "DROP=$drop" \
        -e "OWNER=$(id -u):$(id -g)" \
        --entrypoint sh "$IMAGE" -c '
          set -e
          # Only ever names the launcher offered, so credentials and .claude.json are safe.
          for d in $DROP; do rm -rf "/seed/$d"; done
          tar -xmf - -C /seed --no-same-owner
          if [ -n "$SED_EXPRS" ] && [ -f /seed/settings.json ]; then
            sed -i "$SED_EXPRS" /seed/settings.json
          fi
          chown -R "$OWNER" /seed
        '
  local rc=$?
  [[ -n "$stage" ]] && rm -rf "$stage"
  return $rc
}

seed_interview() {
  seed_detect
  if [[ ${#i_name[@]} -eq 0 ]]; then
    log "no Claude config found on the host, starting clean"
    seed_save_prefs ""
    return 0
  fi
  if [[ ! -t 0 ]]; then
    log "not a terminal, copying the default selection; run --config to change it"
  else
    seed_picker || die "aborted"
  fi
  seed_apply
}
