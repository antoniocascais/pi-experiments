# pi-experiments — running pi non-root in a container

**pi** = `@earendil-works/pi-coding-agent`, a minimal terminal coding agent.
It has no built-in permission system and runs as the calling user, so the
sandbox boundary is the container, not pi itself.

## Do you need root?
No. The `node:24` base image ships a non-root `node` user (uid/gid 1000).
This setup runs as that user (or your host uid via `--user`).

## Build
```bash
docker build -t pi-sandbox -f Dockerfile.pi .
```

## Run (headless, work on a mounted folder)
```bash
cp .env.example .env        # then put your llmbase_ key in it
./run.sh ~/code/myproject "fix the failing tests in src/"
```
Drop the task arg for an interactive session.

## Key bits
- `-v "$PROJECT:/workspace"` — your folder; writes hit host files directly.
- `--user $(id -u):$(id -g)` — files pi creates are owned by you, not root.
- `-v pi-agent-home:/home/node/.pi/agent` — named volume for pi's own
  state. Do NOT bind-mount your host `~/.pi/agent`: it leaks host auth/sessions.
- `-p "<task>"` — print/headless mode, no trust prompt. Stdin is also read
  and merged: `cat spec.md | docker run ... pi-sandbox -p "implement this"`.

## Model provider (llmbase.ai)
OpenAI-compatible endpoint `https://api.llmbase.ai/v1`. Configured in
`models.json` (bind-mounted to the global agent home), selected via
`--provider llmbase --model z-ai/glm-5.2` in `run.sh`.

- API key lives in `.env` as `LLMBASE_API_KEY` (a `llmbase_...` key).
  `run.sh` sources `.env`, passes `-e LLMBASE_API_KEY` into the container,
  and pi interpolates `"$LLMBASE_API_KEY"` from `models.json` at runtime.
  The key is never baked into the image or written into config.
- Verify the exact model id against the catalog:
  `curl https://api.llmbase.ai/v1/models -H "Authorization: Bearer $LLMBASE_API_KEY"`
  (adjust `z-ai/glm-5.2` in `models.json` + `run.sh` if it differs).
- If the endpoint rejects `reasoning_effort` or the `developer` role, add a
  `"compat": { "supportsReasoningEffort": false, "supportsDeveloperRole": false }`
  block to the provider in `models.json`.

## Configuring pi (AGENTS.md)
pi reads `AGENTS.md` (or `CLAUDE.md`) as its context/memory file, searched:
1. `~/.pi/agent/AGENTS.md` (global)
2. parent dirs up from cwd
3. cwd

Headless mode (`-p`) **ignores a project-local AGENTS.md unless you pass `-a`**.
So the default in `AGENTS.md` here is bind-mounted into the *global* slot
(`/home/node/.pi/agent/AGENTS.md`, read-only) by `run.sh` — always loaded,
trusted or not. Edit `AGENTS.md` on the host; no rebuild needed.

Other config files pi understands (same global/project search):
- `.pi/SYSTEM.md` / `~/.pi/agent/SYSTEM.md` — *replace* the system prompt
- `APPEND_SYSTEM.md` — *append* to it
- CLI: `--append-system-prompt "<text>"`, `--system-prompt "<text>"`, `-nc` to disable context files

## Trust model
Headless mode ignores project-local pi config/extensions unless you pass
`-a`/`--approve`. Leaving it off is safer when running pi over untrusted code.

## Hardening (in run.sh)
`--cap-drop ALL`, `--no-new-privileges`, pid/mem limits. For network lockdown
add `--network none` (breaks API calls — only for offline tasks) or put it on
an egress-filtered docker network.

The image strips `npm`/`npx`/`corepack` after install (see `Dockerfile.pi`):
the agent runs on `node` alone and can't fetch arbitrary network packages.
Side effect: it also removes npm's bundled, vulnerable undici (CVE-2026-12151).
If a task genuinely needs Node package tooling, drop the `rm -rf` line.
