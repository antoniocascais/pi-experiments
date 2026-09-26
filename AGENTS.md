# Contributor rules — pi-experiments

This repo builds and runs the container image, not application code. The
agent's own personas live under `pi-home/`, not here (solo: `AGENTS.solo.md`,
crew: `AGENTS.crew.md`).

## Layout

- `Dockerfile`, `.dockerignore` — image build (see `BOM.md` for pins)
- `entrypoint.sh` — per-run config overwrite, provider/model validation, git setup
- `Makefile` — the supported entry point for build/run/scan
- `pi-home/` — baked pi config: `settings.json`, `models.json`, `pi-crew.json`, personas,
  `agents/*.md`, `bin/devsec-tier1.sh`, `extensions/checkpoint.ts`
- `notes-skel/` — seed for the notes ledger, copied onto the state volume once
- `BOM.md` — pinned versions and base image digests

## Rules

- **Public repo.** No private names, hostnames, API keys, tokens, or dated internal session logs
  in any file, comment or commit message.
- Pins live only in the `Dockerfile`'s `ARG` lines and `BOM.md`; bump both together, by digest —
  see `BOM.md` for the exact procedure.
- Nothing may reintroduce `npm`/`npx`/`corepack`/`yarn` into the final image stage.
- Run `make lint`, `make build` and `make scan` before proposing a change.
- Comments explain the WHY, not the HOW; keep them short.
- `entrypoint.sh` and anything under `pi-home/bin/` are POSIX `sh`, must pass `shellcheck`.
- Never commit `.env` or any real credential.
- No push without the repo owner's say-so.
