# pi-experiments

Runs the [pi](https://www.npmjs.com/package/@earendil-works/pi-coding-agent) coding agent in a
hardened, non-root container against a real git checkout. Solo mode (default) is a single
ticket-implementer session; crew mode adds a principal +
[pi-crew](https://www.npmjs.com/package/@melihmucuk/pi-crew) subagents with a review loop and a
durable notes ledger.

## Requirements

- Docker with BuildKit (`make build` sets `DOCKER_BUILDKIT=1`)
- `make`, `jq`
- `shellcheck` (for `make lint`)
- [`trivy`](https://aquasecurity.github.io/trivy/latest/getting-started/installation/) (for `make scan` / `scan-fs`)

## Quickstart

```bash
cp .env.example .env && chmod 600 .env
# edit .env: set PI_PROVIDER, PI_MODEL and the matching *_API_KEY

make build
make clone REPO=$HOME/myrepo   # or a git URL
make up
make pi
```

(Use `$HOME/myrepo`, not `~/myrepo` — zsh does not tilde-expand after `=` in a `make` argument.)

When you're done, get the work back out as a git bundle and review it on the host — see
"Workspace" below:

```bash
make export
git -c transfer.fsckObjects=true fetch pi-export.bundle 'refs/heads/*:refs/remotes/pi/*'
git diff --no-ext-diff --no-textconv main...pi/<branch>
```

Headless, one-shot, solo mode only — no TTY, safe to pipe or run in CI — against the volume worktree from `make clone`:

```bash
make run TASK="fix the failing tests in src/"
```

## Configuration

Everything is set through the env file (`ENV_FILE`, default `.env`), copied from `.env.example`:

| Var | Required | Meaning |
| --- | --- | --- |
| `PI_PROVIDER` | yes | provider key from `pi-home/models.json` |
| `PI_MODEL` | yes | model id offered by that provider |
| `PI_THINKING` | no | thinking level, e.g. `low`/`medium`/`high` |
| `PI_MODE` | no | `solo` (default) or `crew` |
| `LLMBASE_API_KEY` | if using `llmbase` | key for `https://api.llmbase.ai/v1` |
| `CORTECS_API_KEY` | if using `cortecs` | key for `https://api.cortecs.ai/v1` |

Two providers ship out of the box:

```bash
# llmbase
PI_PROVIDER=llmbase
PI_MODEL=minimax/minimax-m3   # or z-ai/glm-5.2
LLMBASE_API_KEY=...

# cortecs
PI_PROVIDER=cortecs
PI_MODEL=deepseek-v4.1-flash
CORTECS_API_KEY=...
```

The entrypoint fails fast if `PI_PROVIDER`/`PI_MODEL` are missing or don't
resolve in `models.json`. Only the selected provider's key needs to be set;
the other may stay empty. Adding a provider or model means editing
`pi-home/models.json` and rebuilding.

Config under `pi-home/` (settings, models, pi-crew agents, `AGENTS.md`,
`agents/`, `extensions/`, `bin/`) is image-owned and **overwritten on every
run** onto the state volume — only `sessions/` and the baked `npm/` install
persist. Customising it means editing the repo and rebuilding, not editing
the running container.

Make variables: `WORKSPACE`, `REPO`, `OUT` (bundle path for `make export`, default
`pi-export.bundle`), `NETWORK`, `MEMORY` (default `8g`), `CPUS` (default `4`), `WITH_GO`,
`WITH_PYTHON`, `BUILD_FLAGS` (build-time — set on `make build`, e.g. `BUILD_FLAGS=--no-cache`), `GH_TOKEN_CMD`, `ENV_FILE`.

`up`, `exec`, `pi` and a URL `clone` run through the entrypoint and need a valid env file
(`PI_PROVIDER`/`PI_MODEL` set). `export` and a local-dir `clone` need none and run with
`--network none`.

`make up` hashes the whole env file plus the image id, `NETWORK`, `WORKSPACE`'s absolute path,
`MEMORY` and `CPUS`, and stores it on the container. Any change to any of those — including
editing `PI_THINKING`, rotating a key, or rebuilding the image — makes the hash on the next
`make up` disagree with the running container's, and `up` fails with a `make down && make up`
hint instead of silently starting stale config.

## Modes

- **solo** (default): one implementer session with `read`/`grep`/`find`/`ls`/`bash`/`edit`/`write`.
  Persona in `pi-home/AGENTS.solo.md`. No `pi-crew` extension loaded.
- **crew**: a principal (no `write`, `pi-crew` loaded) delegates to `worker`/`scout`/`planner`/
  `oracle`/`code-reviewer`/`quality-reviewer` plus the repo's own `implementer`/`researcher`/
  `reviewer`/`adversarial-reviewer`/`devsec-reviewer` agents, with a two-round review loop and a
  dated notes ledger under `$NOTES_ROOT`. Law in `pi-home/AGENTS.crew.md`. Interactive only
  (`make pi`): pi-crew subagents are async and die when a headless `pi -p` exits, so
  `make run TASK=` refuses crew mode.

## Workspace

Default: the agent works on a volume-owned clone, nothing here ever touches a host repo directly.

```bash
make clone REPO=$HOME/myrepo   # or a git URL; a local dir is bundled over stdin, no token/network
make up
```

Get the result back with `make export`: it writes the worktree's branches to a git bundle
(`OUT`, default `pi-export.bundle`) with no env file needed and no egress (`--network none`). A
bundle carries no config or hooks — unlike a bind mount, it's safe to fetch straight into a repo
you care about:

```bash
git -c transfer.fsckObjects=true fetch pi-export.bundle 'refs/heads/*:refs/remotes/pi/*'
git diff --no-ext-diff --no-textconv main...pi/<branch>
```

For a later review of what the agents did, `make export-logs` writes `pi-logs.tar.gz` (0600):
every session as JSONL plus a rendered HTML page, subagents included, and the notes ledger.
Transcripts hold whatever the agent read or printed, so treat the tarball as sensitive.

Fetching runs nothing. Checking the branch out or diffing it can still trigger `.gitattributes`
filters or textconv drivers that your own git config already defines, and `.gitmodules` only
matters if you run `git submodule update`. Review the diff before running the code.

**Bind-mount (`WORKSPACE=`) is opt-in, not the default, and is not fully host-safe:**

```bash
make up WORKSPACE=$HOME/myrepo
```

`.git/config` and `.git/hooks` are mounted **read-only**, and a `WORKSPACE` whose `.git` is a
*file* (a worktree or submodule) is refused outright — but the read-only mounts only stop the
agent overwriting those files *directly*. The agent can still redirect git elsewhere it can write
(e.g. `.git/commondir`) to reach its own config, hooks, pager or diff/textconv filters, and
in-tree auto-exec files (`.envrc`, `.vscode/*`, scripts your shell runs) are untouched by any of
this. Treat a bind-mounted repo as untrusted on the host afterwards: inspect `.git` before running
git or other tooling in it. Prefer clone + export for anything you don't already trust.

## GitHub access

No GitHub credential is baked into the container or the env file — `GITHUB_TOKEN`/`GH_TOKEN` in
`ENV_FILE` is refused outright. Instead, set `GH_TOKEN_CMD` to a host command that prints a token
on stdout; it's run through `sh -c` (so pipes and quotes in it work) and the result injected as
`-e GITHUB_TOKEN` for exactly one invocation, never written to the container's env, `.git/config`
or the state volume. Required for `make pi-gh`/`sh-gh`; optional for `make clone`, which falls
back to an anonymous clone (fine for a public repo).

Recommended: a GitHub App installation-token mint command (short-lived, scoped), e.g.:

```bash
GH_TOKEN_CMD='my-app-token-mint | jq -r .token'
```

App permissions: Contents (read/write), Pull requests (read/write), Metadata (read). Install the
app only on the target repos. Alternative: `GH_TOKEN_CMD="gh auth token"` or a PAT — broader
scope, an explicit choice, no silent fallback. No minting helper is shipped here.

The agent can read the token for the duration of that session — that's inherent to letting it run
`git`/`gh` commands with it.

## Security model

- Read-only rootfs, `--cap-drop=ALL`, `--security-opt=no-new-privileges`, pids/memory/cpu limits
  (`HARDEN` in the Makefile)
- Runs as a non-root `agent` user; `make build` matches your host uid/gid on Linux
- `npm`, `npx`, `corepack` and `yarn` are removed from the final image after `pi install`
- Base images and toolchains pinned by digest (see `BOM.md`)
- Build context is an allowlist (`.dockerignore` denies everything, then re-allows exactly what's needed)
- `make scan` / `make scan-fs` — trivy vuln + secret scans; both fail if trivy isn't installed
  rather than skipping
- `pi-home/bin/devsec-tier1.sh` is an advisory self-check run by the implementer (solo) or every
  crew round — not a gate; a real security review happens once, at the end, in crew mode
  (`devsec-reviewer`)
- `checkpoint.ts` persists session metadata only (roles, tool names, file paths, counts) —
  never message text or tool arguments

## Egress

**Not filtered.** A host OUTPUT-chain firewall does not see container traffic — it's FORWARDed
past it. The agent has full internet access unless you constrain it yourself:

```bash
make up NETWORK=none      # fully offline (breaks `make pi` itself)
make up NETWORK=<name>    # a docker network you've firewalled
```

The agent can read the provider API key at all times, and the GitHub token during a `-gh` session.

## Make targets

Run `make help` for the full, current list. Grouped summary:

| Group | Targets |
| --- | --- |
| Build & checks | `build`, `lint`, `scan`, `scan-fs`, `versions` |
| Managed container | `up`, `start`, `stop`, `restart`, `down`, `status`, `ps`, `logs` |
| Sessions | `pi`, `sh`, `pi-gh`, `sh-gh`, `continue`, `resume`, `sessions`, `exec` |
| Repo / crew | `clone`, `export`, `export-logs`, `crew-check`, `notes` |
| One-shot | `shell`, `run` |
| Teardown | `state-reset`, `nuke`, `clean` |

## Limitations

- Rootless Docker / Podman: untested.
- macOS: `AGENT_UID`/`AGENT_GID` default to 1000 (no `id -u` lookup); adjust if your host uid differs.
- No automated test suite yet.
