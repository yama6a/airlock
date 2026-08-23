# Airlock

Claude Code in a container on macOS, carrying whichever parts of your host Claude config
you choose. Two things it gives you.

**Isolation.** Claude Code sees the directories you name and nothing else, a copy of your
config it cannot write back to, and none of your host environment.

**Its own auth.** The container logs in separately and inherits no `ANTHROPIC_*`, so it can
run a different account, API key or base URL than your host does, at the same time.

Not to be confused with `stargazerZJ/ccbox`, an LXD sandbox for Linux.

## Requirements

- macOS
- a container runtime with a Docker-compatible CLI

Nothing else. The launcher runs under stock `bash` 3.2 with only `/usr/bin` and `/bin` on
`PATH`. `jq` on the host is optional; without it two picker items are skipped, noted below.

| Runtime                          | Status                |
|----------------------------------|-----------------------|
| Rancher Desktop                  | tested                |
| Docker Desktop, Colima, OrbStack | untested, should work |
| Podman                           | detected and rejected |

Nothing is assumed about the runtime: the launcher asks the daemon for the platform and the
container detects its uid at run time. Podman needs its own handling for user-namespace
mapping, socket discovery and SELinux labelling.

## Use

```bash
git clone <this repo> ~/airlock
cd ~/some/project
~/airlock/airlock
```

- alias it: `alias al=~/airlock/airlock`
- the image builds itself on first run
- `$PWD` is mounted at the same absolute path and becomes the working directory, so paths
  in output are valid on the host too
- nothing outside `$PWD` is mounted unless you name it with `--add-dir-rw` or `--add-dir-ro`

### More than one directory

```bash
airlock --add-dir-rw ~/other/repo --add-dir-ro ~/reference/repo
```

Both flags repeat. Each directory is mounted at its own host path and handed to Claude with
`--add-dir`, so it can read and write across repos in one session and the paths it prints
still mean something on the host. `--add-dir` on its own is the same flag as `--add-dir-rw`.

The same limits as `$PWD` apply: not `/`, not `$HOME`, not inside `~/.claude`, and inside a
path the runtime shares with its VM.

## First run

Two things happen once.

### Choosing what to copy

Airlock looks for Claude config in `$CLAUDE_CONFIG_DIR`, or `~/.claude` when that is unset,
and asks:

```
airlock: Claude config found in /Users/you/.claude

  copy into the container volume
   1 [x] settings.json                              2.1K
   2 [ ] settings.local.json                         708B
   3 [x] CLAUDE.md                                  5.3K
   4 [x] statusline-command.sh                      4.6K
   5 [x] commands/  2 files                          11K
   6 [x] skills/  2 files                            12K
   7 [x] hooks/  1 file                             2.4K
   8 [x] plugins/  740 files                        9.5M

  the only part of .claude.json that can be copied
   9 [ ] MCP servers  3, may hold API keys

  mount from the host on every run
  10 [x] .gitconfig, .gitignore, allowed_signers
  11 [x] .kube/config
  12 [ ] .ssh  private keys
  13 [ ] docker socket  root on the host VM

  never copied: credentials, the rest of .claude.json, projects/, history.jsonl, ...

  number toggles, a=all, n=none, q=abort, Enter=accept
>
```

Items appear only when they exist, so the list matches your machine. Answers are saved to
`~/.config/airlock/config` and reused; `--config` asks again and re-copies.

Selected config is **copied** into a persistent volume, not mounted. The container cannot
change your host config, and host edits do not reach a container until you run `--config`.
Symlinks are resolved on the way in, so a config kept in a dotfiles repo, a synced folder
or anywhere else arrives as real files.

`.gitconfig`, kubeconfig and `~/.ssh` work differently: they are bind-mounted read-only and
copied into place at every start, so they stay current. SSH keys and the Docker socket
default to off; Anthropic's own devcontainer guidance advises against mounting host secrets,
and a mounted socket is root on the host VM.

### Logging in

The container authenticates on its own, which is the point: whatever it ends up using is
independent of what your host is using.

Credentials also could not come from the host if you wanted them to. macOS keeps them in the
Keychain, which the Linux binary cannot read, and a copied `.credentials.json` dies within one
token lifetime because refresh tokens rotate and whichever machine redeems one invalidates it
for the other. Upstream closed that request as not planned.

Start `airlock` and run `/login`. The browser callback targets `localhost` and cannot reach
the container, so use the built-in fallback:

1. press `c` to copy the login URL
2. open it on the host, approve
3. paste the code back at the terminal prompt

`/status` then shows what the container is on, which is the check that matters.

The login lives in the same volume as the config and survives `--rm` and rebuilds. Only
`--reset` discards it. Logins carry a multi-day hard expiry, so expect to repeat this
occasionally.

To skip the login entirely, hand it an API key instead and it never prompts:

```bash
airlock -e ANTHROPIC_API_KEY=sk-...
airlock -e ANTHROPIC_BASE_URL=https://my-gateway.example.com -e ANTHROPIC_AUTH_TOKEN=...
```

## Flags

| Flag                  | Effect                                          |
|-----------------------|-------------------------------------------------|
| `--config`            | choose again what to copy, and re-copy          |
| `--build`             | rebuild the image and exit                      |
| `--shell`             | run bash in the claude container                |
| `--no-yolo`           | run without `--dangerously-skip-permissions`    |
| `-e`, `--env NAME=v`  | set an env var in the container, repeatable     |
| `--add-dir-rw DIR`    | mount another directory too, repeatable         |
| `--add-dir-ro DIR`    | the same, read-only, repeatable                 |
| `--reset`             | wipe everything persisted and exit, see below   |

Anything else passes through, so `airlock -p 'summarise this repo'` works, pipes included.
Without a terminal the picker is skipped and the defaults are copied.

### --env

```bash
airlock -e MAX_THINKING_TOKENS=31999 --env DISABLE_TELEMETRY=1
airlock --env GITHUB_TOKEN            # no '=', forwards the host's value
```

- `--env=NAME=value` works too; unset on the host means skipped with a log line
- `-e` never reaches `claude`, the launcher takes it
- nothing is refused, and `ANTHROPIC_*` is how you point the container at a different account
  or endpoint from the one the host is on
- for the same vars on every run, use an `env` block in the `settings.json` you copy in

## Starting over

Three things persist between runs:

| What                                                           | Where                      |
|----------------------------------------------------------------|----------------------------|
| Copied config, the login, and session state Claude accumulates | volume `airlock-config`    |
| npm, uv and Go module caches                                   | volume `airlock-cache`     |
| Which items you chose to copy and mount                        | `~/.config/airlock/config` |
| Build stamp, for the "image is stale" warning                  | `~/.cache/airlock/built`   |

`airlock --reset` removes all four and exits without starting anything. The next run is
a first run: the picker asks with stock defaults, and you log in again.

It keeps the image, since that holds no state. Delete it with
`docker rmi airlock:latest` if you want the next run to rebuild.

To change only what gets copied, without losing the login, use `--config` instead.

## Environment

| Variable                                                                        | Effect                                        |
|---------------------------------------------------------------------------------|-----------------------------------------------|
| `AIRLOCK_HOME`                                                                  | container home; defaults to the host `$HOME`  |
| `AIRLOCK_USER`                                                                  | container user name; defaults to `id -un`     |
| `CLAUDE_CONFIG_DIR`                                                             | where to look for host config, read on the host |
| `AIRLOCK_NO_SSH`, `AIRLOCK_NO_KUBE`, `AIRLOCK_NO_GIT`, `AIRLOCK_NO_DOCKER_SOCK` | override a saved choice for one run           |
| `AIRLOCK_FIX_SIGNING=0`                                                         | leave a literal ssh `user.signingkey` alone   |
| `AIRLOCK_COPY_KUBECONFIG=0`                                                     | do not copy the kubeconfig to a writable path |
| `AIRLOCK_ENGINE`, `AIRLOCK_IMAGE`, `AIRLOCK_VOLUME`, `AIRLOCK_PLATFORM`         | overrides                                     |

## What is never copied

Excluded by name, not offered in the picker: `.credentials.json`, `.claude.json` (one
exception below), `projects/`, `history.jsonl`, `file-history/`, `sessions/`, `session-env/`,
`shell-snapshots/`, `telemetry/`, `backups/`, and the caches.

Two of those are worth explaining.

**`.claude.json` is generated, not copied.** It holds your OAuth account, user id, machine
id, per-project state and a large pile of caches. The container writes its own with the two
keys that matter, `hasCompletedOnboarding` and `autoUpdates`.

One key can come across: **`mcpServers`**, offered in the picker and **off by default**,
because MCP definitions often carry inline API keys and you should decide that per machine.
Selecting it stages just that key and merges it into the generated `.claude.json` the first
time the container starts. Nothing else from the host file moves. Leave it off and add
servers inside with `claude mcp add`, which persists in the volume either way.

**`projects/` is skipped, which also skips memory.** That directory is mostly session
transcripts, often hundreds of megabytes, but it is also where Claude's auto-memory lives
(`projects/*/memory/MEMORY.md`). Skipping the directory means the container starts without
that memory. Copy those files in by hand if you want them.

## In the image

`ubuntu:24.04`. Versions are `ARG`s at the top of the `Dockerfile`; helm is held on the 3.x
line because 4.x is a breaking major.

git, git-lfs, gh, tig, curl, wget, jq, yq, ripgrep, fd, tree, make, gawk, GNU coreutils,
openssh-client, vim, less, rsync, socat, dnsutils, build-essential, Docker CLI with buildx
and compose, kubectl, helm, kubectx, kubens, k9s, kustomize.

**Databases.** `sqlite3`, and `psql` plus `pgcli` from the PGDG apt repo rather than Ubuntu's,
which is a major behind. The client major is `PG_MAJOR` in the `Dockerfile` and is bumped by
hand, since Renovate has no way to read a major out of a package name. A newer client talks to
older servers.

**Go tooling.** `gopls`, `gofumpt`, `golangci-lint`, `govulncheck`, `oapi-codegen`. All at
`/usr/local/bin`, so they survive `--rm` and need no `go install` per session. golangci-lint
comes from the release tarball, not `go install`, which upstream asks for because a source
build loses the version metadata the linter reports.

## Plugins and MCP servers

The runtimes plugins actually launch with are all present, so a plugin can be added and used
without touching the image.

| Runtime              | Unlocks                                                                                                                                        |
|----------------------|------------------------------------------------------------------------------------------------------------------------------------------------|
| `node`, `npx`, `npm` | most MCP servers: context7, playwright, filesystem, memory, sequential-thinking, notion, supabase, figma, mcp-remote, and the node-backed LSPs |
| `uv`, `uvx`          | Python servers, which document `uvx` rather than pip: fetch, git, time, sqlite, serena, the awslabs family                                     |
| `python3`, `pip`     | plugin hooks that shell out to `python3` directly, such as hookify and security-guidance                                                       |
| `go`, `gopls`        | the Go LSP plugin and Go tooling                                                                                                               |
| Docker CLI           | servers distributed as images, when the socket is mounted                                                                                      |
| Chromium, headless   | playwright, puppeteer, chrome-devtools                                                                                                         |

**Playwright works headless with no setup.** Chromium and its 61 system libraries are baked
in, installed by `playwright install --with-deps` so the package list always matches the
Playwright version rather than being hand-maintained. Verified in the container: a real page
loads over the network and `@playwright/mcp` starts and exposes its full tool set. The
container also runs with `--shm-size=1g`, because Chromium crashes on real pages with
Docker's default 64 MB `/dev/shm`.

**Package caches live in a second volume**, `airlock-cache`, mounted at `~/.cache` with npm
and the Go module cache redirected into it. Without it every session re-downloads each MCP
server from scratch. Pin versions in your MCP config rather than using `@latest`: a pinned
server starts in about half the time, since `@latest` forces a registry round trip whatever
the cache holds.

**Not included.** `bun`, which four messaging plugins need and which node does not satisfy;
`java` and `mvn`; cloud CLIs; and the language servers behind the other LSP plugins, which
expect their own toolchain or a global npm install. Add what you need with `FROM
airlock:latest`.

## Notes

**Copying resolves symlinks, deliberately.** The copy is a `tar --dereference` stream piped
into the volume, so a symlinked config arrives as real files rather than links pointing at
host paths that do not exist in the container. Two traps that shaped this: `tar -cL` must
never be used, because to GNU tar `-L` means `--tape-length` and swallows an argument; and
`--dereference` stores a *dangling* symlink as a symlink and exits 0, so dangling links are
found and excluded first, otherwise they arrive looking like the dereference failed.

**Scripts your settings point at are found and copied.** A `statusLine.command` or hook
command can name a script anywhere on the host. Those are detected, offered in the picker,
copied into the volume, and the paths in the copied `settings.json` are rewritten to match.
Without `jq` on the host this and the MCP item are both skipped, and the container warns at
startup about any command path it cannot find.

**Isolation here is filesystem and config, not network.** The container reaches whatever the
host can reach. Nothing filters its egress.

**The container uid is detected, not assumed.** How a bind-mounted host file presents inside
a container depends on the runtime's mount technology:

| Mount tech           | Presents as                                 | Seen on                         |
|----------------------|---------------------------------------------|---------------------------------|
| sshfs, 9p            | the real host uid                           | Rancher Desktop, Colima on qemu |
| virtiofs             | the uid the container asks for              | OrbStack, Colima on vz          |
| Docker Desktop's own | virtualized into an xattr, sometimes `root` | Docker Desktop                  |

So the entrypoint reads the workspace's owner, confirms that uid can actually write there,
and falls back to a hint from the launcher. It writes `/etc/passwd` directly, because
`useradd` rejects the large uids directory-joined machines hand out.

**Commit signing gets repointed.** A literal ssh public key in `user.signingkey` makes git
sign through `ssh-keygen -Y sign -U`, which resolves the private half through ssh-agent, and
no macOS runtime can forward an agent into a container. Left alone, every commit fails
outright rather than going unsigned. So the entrypoint:

- matches the key against `~/.ssh` by fingerprint
- points `user.signingkey` at the file
- derives the `<key>.pub` sidecar `ssh-keygen` needs
- skips passphrase-protected keys, since unlocking one needs an agent
- disables signing if nothing matches, so commits still work

**Do not keep `~/.claude` in iCloud Drive, Dropbox or Google Drive Stream.** Those evict
file contents to stubs, so a copy reads a file that appears to exist and is empty.

**A mounted Docker socket means this is not a security boundary.** Access to the daemon is
escalation to root on the host or its VM.

**Rate limits are shared when both sides use the same account.** Log the container into a
different one, or give it an API key, and they are separate.

## Working on it

```bash
./test/smoke.sh            # syntax, flag parsing, and the seed copy. No runtime needed
shellcheck airlock lib/seed.sh entrypoint.sh test/smoke.sh
```

CI runs both, plus a full image build, and those are the required checks that let Renovate
merge its own grouped update PR. A fork needs a `RENOVATE_TOKEN` secret and Issues enabled
before the Renovate workflow does anything.

Every pinned version is an `ARG` at the top of the `Dockerfile` with a `# renovate:` line
above it naming its datasource. An `ARG` without that line never gets updated.

## Licence

MIT, see `LICENSE`.
