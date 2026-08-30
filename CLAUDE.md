# Airlock project conventions

Runs Claude Code in a container on macOS, isolated from the host and authenticating on its
own, so it can be on a different account or endpoint than the host at the same time. Host
Claude config is detected, chosen from a picker, and COPIED into a Docker volume with
symlinks resolved. No config is bind-mounted. macOS only: the launcher dies on anything else,
so no code path branches on the platform.

## Layout

Four files, one job each. Keep it that way.

| Path                       | Holds                                                                      |
|----------------------------|----------------------------------------------------------------------------|
| `airlock`                  | host side. Flags, engine and platform detection, the mount set, the run    |
| `lib/seed.sh`              | sourced by the launcher. Candidate detection, the picker, the copy         |
| `entrypoint.sh`            | container side. Identity, host material, privilege drop. Root, then `gosu` |
| `Dockerfile`               | the image. Every pinned version is an `ARG` at the top, nowhere else       |
| `README.md`                | the WHY. Every non-obvious reason lives here by default                    |
| `test/smoke.sh`            | everything checkable without a runtime. CI runs it on `macos-latest`      |
| `renovate.json5`           | every pin in the repo, and which manager owns it                          |
| `~/.config/airlock/config` | not in the repo. The user's picker answers, `KEY=value`, sourced           |

## Constraints

- `airlock` and `lib/seed.sh` run under stock macOS `bash` 3.2 with `PATH=/usr/bin:/bin`.
  No `mapfile`, no associative arrays, no `globstar`, no Homebrew GNU tools. Parallel arrays
  where a map is wanted.
- `entrypoint.sh` runs under the image's bash, so no 3.2 limit.
- Host `jq` is optional. A feature needing it degrades with one `log` line.
- Config is copied, never bind-mounted: a bind mount lets the container change host config,
  and a file bind mount pins an inode.
- Nothing personal anywhere. Everything from `$HOME`, `id -un`, or a `AIRLOCK_*` variable.
- ASCII only.

## Comments

Default is ZERO. The code, the variable name, and the `log`/`die` string beside it ARE the
documentation. A comment is an exception you justify, not a habit.

**The threshold.** Write for a developer who knows bash, Docker and macOS but not this
project.

- Obvious to them? Nothing. `mkdir -p "$CONFIG_DIR"`, `chmod 0600`.
- Needs bsdtar versus GNU tar, how a runtime maps bind-mount ownership, Claude Code's config
  layout, `/etc/passwd` internals or OpenSSH signing? Explain it, as briefly as you can
  without jargon. `SSH_ASKPASS_REQUIRE=force` is this kind. `--no-same-owner` is not.

**The rules.**

- Short. Same line as the thing it documents. Two lines is usually already too much.
  Paragraphs never. Fragments over sentences.
- Be right before brief. A confidently wrong comment is worse than none.
- Name it in plain words. `SSH_ASKPASS_REQUIRE=force` alone says nothing; say it stops
  `ssh-keygen` reaching for `/dev/tty`. Cannot say what an identifier means? You do not know
  why the line is there.
- Say what it DOES before why we chose it. If the name already says what it does, skip to the
  why or write nothing.
- Finish with "so ...". "sshfs is a FUSE filesystem" is noise; "sshfs cannot proxy a socket,
  so mount the VM-local path" is information. Nothing after the "so"? Delete the line.
- Say what to DO, not what category it belongs to.
- Do not inflate stakes. No shouted labels. State the real consequence even when mild.
- Name the gap. A container stops being a boundary once the Docker socket is mounted.
- Comment the line, not the mechanism.
- Do not reach into another file for a reason the local line already carries.
- Only thing worth saying is "this is redundant"? Delete the redundant thing.
- Never restate a version. Point at the `Dockerfile` `ARG`. Never explain what a version
  changed: we roll forward. Only a forward constraint earns digits, a floor or a ceiling.
- Keep "source of truth", "invariant", "idempotent", "trade-off", "deliberately X: <reason>".
  Drop a bare "deliberately" with no reason after it.

**Banned filler:** idiom, house style, posture, load-bearing, cardinal, moot, orthogonal,
nuance, semantics, non-trivial, canonical, "the whole point", "reads as", "earns its keep".
Concrete verb instead: "GNU tar reads -L as --tape-length", not "the flag is not portable".

**Earns one:** an outside constraint behind a weird construction; a value that looks wrong or
arbitrary; a footgun for whoever edits THAT line next; a non-default over the obvious default;
a coupling invisible from here (the launcher writes it, the engine creates it); a manual
ordering the code cannot express.

**Never:** restating the line; teaching bash, Docker or tar; history, what it used to be, what
a bug did; anything a `log`, `die` or `--help` string already says; rationale and trade-offs,
which go to `README.md`; counts and measurements; doc pointers beyond one per file.

**Form.**

- Trailing beats a block above. A block above is for a whole file.
- A file header, when earned, is ONE line.
- Attach to the exact line, not the block it sits in.
- Group with a blank line, not a banner. `# ---- knobs ----` is the one exception.
- Show the result, do not describe it.

**The test.** Would that developer already understand the line? If yes, nothing. If no, the
shortest comment that leaves them able to DO something, and not a word past that.

## Per file type

- `airlock`, `lib/seed.sh`: the `log`/`die` string IS the comment. One trailing comment per
  non-obvious knob. Never a banner over a function, never narration of the code below.
- `entrypoint.sh`: same. It runs as root before dropping, so a line whose failure mode is
  permissions or ownership gets one line saying which.
- `Dockerfile`: comments go ABOVE the `RUN`. Never trailing inside a line-continued `RUN`, the
  block is one logical line so `#` kills the rest of it. `ARG` names already say what they pin.
- `README.md`: bullets and tables. A paragraph only for a mechanism that needs prose, three
  sentences max.
- Picker strings are user-facing UI, not comments. Terse, no jargon, say what a choice DOES:
  "private keys", "root on the host VM".

## Where a value lives

| Value                                               | Lives in                                            |
|-----------------------------------------------------|-----------------------------------------------------|
| Pinned tool versions                                | `Dockerfile` `ARG`s                                 |
| Image and volume names, launcher defaults           | `# ---- knobs ----` in `airlock`                    |
| Which config items exist, and their picker defaults | `SEED_KNOWN` in `lib/seed.sh`                       |
| Where a pinned version comes from                   | a `# renovate:` line above its `ARG`                |
| The user's answers                                  | `~/.config/airlock/config`, via `seed_save_prefs`   |
| Container user, home, uid                           | env the launcher passes. Never hardcoded or assumed |
| Rationale and trade-offs                            | `README.md`                                         |

## Invariants

Each cost real time to find. Do not re-derive them.

- **`tar`**: never `-L`, GNU tar reads it as `--tape-length` and eats an argument. One
  invocation with several `-C` sections, since concatenated archives silently drop everything
  after the first end marker. `--dereference` stores a DANGLING link as a link and exits 0, so
  pre-scan and exclude. `--no-mac-metadata --no-xattrs --no-fflags` or macOS metadata arrives.
- **`du`** reports disk blocks and follows nothing. `-L` for a symlink; sum apparent bytes for
  a size a user reads.
- **Probe the container uid, never assume it.** Bind-mount ownership differs per runtime: real
  host uid on sshfs and 9p, the container's own on virtiofs, virtualized on Docker Desktop.
  `chown` on a bind mount fails outright on sshfs.
- **A host Unix socket is visible through every mount type but not connectable.** `[ -S ]`
  passes, connect fails later. Mount the VM-local `/var/run/docker.sock`.
- **`ssh-keygen` reads passphrases from `/dev/tty`** even with stdin redirected.
- **`CLAUDE_CONFIG_DIR` relocates `.claude.json` INTO that directory**, not beside it.
- **The engine creates a missing bind-mount target as root**, so parents need chowning.
- **`useradd` rejects large uids**, so `/etc/passwd` is written directly.
- **A container filesystem write is discarded by `--rm`.** Anything that must survive goes in
  a volume: config in `airlock-config`, package caches in `airlock-cache`, `~/.config` and so
  the `gh` login in `airlock-state`. npm and the Go module cache do not default under
  `~/.cache`, so the entrypoint redirects them.
- **Chromium needs more than 64 MB of `/dev/shm`** or it dies on real pages, hence
  `--shm-size` on the run. Let `playwright install --with-deps` choose the apt packages rather
  than pinning a list that goes stale against the Playwright version.

## Verifying a change

Piped stdin makes `airlock` withhold `-t`, which hides anything reading `/dev/tty` and makes
the picker skip itself. Interactive paths need a pty.

```bash
./test/smoke.sh                                           # syntax, flags, and the seed copy
script -q /dev/null ./airlock --shell < commands.txt      # allocates a pty
```

`test/smoke.sh` already builds the throwaway `.claude` that breaks naive implementations:
symlinks into a flat dir plus one dangling link. It lives under the real `$HOME`, not `/tmp`,
because only `$HOME`, `/Users` and `/Volumes` are accepted. Drive `seed_picker` directly when
you change toggles, the smoke test drives `seed_detect` and `seed_apply` instead.

Then: no symlinks survive in the volume, the uid matches the workspace owner, a file written
in the workspace is host-owned, `env | grep -i anthropic` is empty, `claude -p` answers, and
the host's `~/.claude` and `~/.claude.json` are byte-identical across a run.
