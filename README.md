# Airlock

Claude Code in a container on macOS, carrying whichever parts of your host Claude config you
choose.

- sees only the directories you name
- gets a copy of your config, never writes back to it
- logs in on its own, so it can run a different account, API key or base URL than your host,
  at the same time

Not `stargazerZJ/ccbox`, which is an LXD sandbox for Linux.

## Requirements

- macOS
- a container runtime with a Docker-compatible CLI
- `jq` optional; without it, two picker items are skipped

| Runtime                          | Status                |
|----------------------------------|-----------------------|
| Rancher Desktop                  | tested                |
| Docker Desktop, Colima, OrbStack | untested, should work |
| Podman                           | rejected              |

## Use

```bash
git clone <this repo> ~/airlock
cd ~/some/project
~/airlock/airlock
```

- alias it: `alias al=~/airlock/airlock`
- image builds itself on first run
- `$PWD` is mounted at the same absolute path, so printed paths work on the host too
- nothing else is mounted unless you name it

```bash
airlock --add-dir-rw ~/other/repo --add-dir-ro ~/reference/repo
```

Both flags repeat and are handed to Claude as `--add-dir`. Not allowed: `/`, `$HOME`, inside
`~/.claude`, or outside a path the runtime shares with its VM.

## First run

### What gets copied

Airlock reads `$CLAUDE_CONFIG_DIR`, or `~/.claude`, and asks:

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

- only items that exist are listed
- answers saved to `~/.config/airlock/config`; `--config` asks again and re-copies
- config is copied, not mounted, and symlinks are resolved on the way in
- `.gitconfig`, kubeconfig and `~/.ssh` are the exception: re-read from the host every start
- no terminal means no picker, defaults get copied

### Logging in

Host credentials cannot be reused: they live in the macOS Keychain, and a copied token dies
as soon as either side refreshes it.

Run `/login` inside the container. The browser callback cannot reach it, so:

1. press `c` to copy the login URL
2. open it on the host, approve
3. paste the code back

`/status` confirms. The login is stored in the volume and survives rebuilds; only `--reset`
drops it. Expect to redo it every few days.

Or skip login with a key:

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
| `--reset`             | wipe everything persisted and exit              |

Anything else passes through: `airlock -p 'summarise this repo'`, pipes included.

### --env

```bash
airlock -e MAX_THINKING_TOKENS=31999 --env DISABLE_TELEMETRY=1
airlock --env GITHUB_TOKEN            # no '=', forwards the host's value
```

- `--env=NAME=value` works too; unset on the host is skipped with a log line
- nothing is refused; `ANTHROPIC_*` is how you point at another account or endpoint
- for the same vars every run, put an `env` block in the `settings.json` you copy in

## Starting over

| What                                                | Where                      |
|-----------------------------------------------------|----------------------------|
| Copied config, the login, Claude's session state    | volume `airlock-config`    |
| npm, uv and Go module caches                        | volume `airlock-cache`     |
| Your picker answers                                 | `~/.config/airlock/config` |
| Build stamp for the stale-image warning             | `~/.cache/airlock/built`   |

`airlock --reset` removes all four and exits. Next run is a first run. The image is kept;
`docker rmi airlock:latest` to force a rebuild. To change only what is copied, use `--config`.

## Environment

| Variable                                                                        | Effect                                          |
|---------------------------------------------------------------------------------|-------------------------------------------------|
| `AIRLOCK_HOME`                                                                  | container home; defaults to the host `$HOME`    |
| `AIRLOCK_USER`                                                                  | container user name; defaults to `id -un`       |
| `CLAUDE_CONFIG_DIR`                                                             | where to look for host config, read on the host |
| `AIRLOCK_NO_SSH`, `AIRLOCK_NO_KUBE`, `AIRLOCK_NO_GIT`, `AIRLOCK_NO_DOCKER_SOCK` | override a saved choice for one run             |
| `AIRLOCK_FIX_SIGNING=0`                                                         | leave a literal ssh `user.signingkey` alone     |
| `AIRLOCK_COPY_KUBECONFIG=0`                                                     | do not copy the kubeconfig to a writable path   |
| `AIRLOCK_ENGINE`, `AIRLOCK_IMAGE`, `AIRLOCK_VOLUME`, `AIRLOCK_PLATFORM`         | overrides                                       |

## Never copied

`.credentials.json`, `projects/`, `history.jsonl`, `file-history/`, `sessions/`,
`session-env/`, `shell-snapshots/`, `telemetry/`, `backups/`, caches.

`.claude.json` is generated fresh, not copied. One key can come across, `mcpServers`, offered
in the picker and off by default since MCP definitions often hold inline API keys. Otherwise
use `claude mcp add` inside; it persists either way.

Skipping `projects/` also skips Claude's auto-memory (`projects/*/memory/MEMORY.md`). Copy
those in by hand if you want them.

## In the image

`ubuntu:24.04`. Versions are `ARG`s at the top of the `Dockerfile`.

- git, git-lfs, gh, tig, curl, wget, jq, yq, ripgrep, fd, tree, make, gawk, GNU coreutils,
  openssh-client, vim, less, rsync, socat, dnsutils, build-essential
- Docker CLI with buildx and compose, kubectl, helm, kubectx, kubens, k9s, kustomize
- `sqlite3`, `psql` and `pgcli` from PGDG, a major ahead of Ubuntu's
- `gopls`, `gofumpt`, `golangci-lint`, `govulncheck`, `oapi-codegen`, all in `/usr/local/bin`
- Chromium plus its system libraries, so Playwright runs headless with no setup

Not included: `bun`, `java`, `mvn`, cloud CLIs, and the language servers behind the non-Go LSP
plugins. Add them with `FROM airlock:latest`.

## Plugins and MCP servers

Plugin runtimes are all present, so plugins work without touching the image.

| Runtime              | Unlocks                                                                                    |
|----------------------|--------------------------------------------------------------------------------------------|
| `node`, `npx`, `npm` | most MCP servers: context7, playwright, filesystem, memory, notion, supabase, figma, LSPs  |
| `uv`, `uvx`          | Python servers: fetch, git, time, sqlite, serena, the awslabs family                       |
| `python3`, `pip`     | plugin hooks that shell out to `python3`                                                   |
| `go`, `gopls`        | the Go LSP plugin and Go tooling                                                           |
| Docker CLI           | servers shipped as images, when the socket is mounted                                      |
| Chromium, headless   | playwright, puppeteer, chrome-devtools                                                     |

Pin versions in your MCP config. `@latest` forces a registry round trip every start, roughly
doubling startup time whatever the cache holds.

## Caveats

- mounted Docker socket: root on the host VM, not a boundary
- ssh keys off by default, on request only
- no network isolation, egress unfiltered
- same account both sides: shared rate limits
- `~/.claude` in iCloud, Dropbox or Drive Stream: copies come out empty

## Licence

MIT, see `LICENSE`.
