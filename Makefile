# pi-experiments — build, scan and run the pi agent container.
# Recipes use bash-only constructs; CI runners default /bin/sh to dash.
SHELL := /bin/bash

IMAGE     := pi-experiments
TAG       ?= local
VOLUME    ?= pi-experiments-state
CONTAINER ?= pi-experiments

WITH_GO     ?= 0
WITH_PYTHON ?= 0
BUILD_FLAGS ?=

# Default: the agent works on a volume-owned clone (`make clone REPO=...`),
# gotten back out with `make export` -- nothing here can reach a host repo.
# WORKSPACE bind-mounts a host checkout instead; it's opt-in and NOT fully
# host-safe even with the read-only mounts below (see WORKSPACE_CHECK, README).
WORKSPACE ?=

# Repository for `make clone`: a URL, or an existing local directory (bundled
# from the host's own trusted copy over stdin -- no token, no network needed).
REPO ?=

# Output path for `make export`.
OUT ?= pi-export.bundle
# Output path for `make export-logs`.
LOGS_OUT ?= pi-logs.tar.gz

# The api key(s) reach the container through this file and nothing else. It
# should be mode 0600 and is excluded from the build context by .dockerignore;
# --env-file keeps the value out of argv (i.e. out of `ps`).
ENV_FILE ?= .env

# Host command that prints a GitHub token on stdout, used only for pi-gh/sh-gh/
# clone and only for the duration of that one exec -- never baked into the
# container's environment. A GitHub App install-token mint command is
# recommended (least privilege, short-lived); `gh auth token` or a PAT also
# work, but pick one explicitly -- there's no silent fallback. See README.
GH_TOKEN_CMD ?=
# Exported (not textually substituted) so pipes/quotes in it survive intact --
# see MINT_TOKEN below.
export GH_TOKEN_CMD

# Resource caps, overridable, plus the same hardening every container here gets.
MEMORY ?= 8g
CPUS   ?= 4
HARDEN_BASE := --read-only --tmpfs /tmp --cap-drop=ALL --security-opt=no-new-privileges \
               --pids-limit=512 --memory $(MEMORY) --cpus $(CPUS)
HARDEN := $(HARDEN_BASE)

# ⚠️ Container egress is NOT filtered by a host OUTPUT-chain firewall: container
# traffic is FORWARDed past it. The agent has unrestricted internet access
# unless constrained here.
#   NETWORK=none    fully offline -- good for reviews/lint/tests on a cloned repo
#                   (pi itself cannot reach the model gateway, so `make pi` will fail)
#   NETWORK=<name>  attach to a docker network you have firewalled yourself
# See README "Egress: read this before trusting the sandbox".
NETWORK ?=
ifneq ($(strip $(NETWORK)),)
HARDEN += --network $(NETWORK)
endif

RUN_FLAGS := --rm -it $(HARDEN) -v $(VOLUME):/state
ifneq ($(wildcard $(ENV_FILE)),)
RUN_FLAGS += --env-file $(ENV_FILE)
endif
# Same, minus the TTY, for targets that are piped or run in CI.
RUN_FLAGS_BATCH := $(filter-out -it,$(RUN_FLAGS))

TASK ?=

# Managed container (`make up`/`stop`/`down`): a long-lived container that just
# sleeps, so sessions/caches survive closing the terminal. `make pi` execs into
# it with a real TTY (pi is a TUI; a detached one has nowhere to draw).
PI_ARGS ?=
# `no` by default: an autonomous agent's container should come back because
# you asked, not because the host rebooted. RESTART=unless-stopped to change that.
RESTART ?= no

DAEMON_FLAGS := -d --name $(CONTAINER) --restart $(RESTART) $(HARDEN) -v $(VOLUME):/state
ifneq ($(wildcard $(ENV_FILE)),)
DAEMON_FLAGS += --env-file $(ENV_FILE)
endif

# `docker exec` does not run the image's ENTRYPOINT, so it would skip the
# per-run config overwrite and key sanitising the entrypoint does. Re-entering
# through it keeps every exec/pi/sh consistent with a fresh `docker run`.
EXEC_ENTRY := /usr/local/bin/pi-experiments-entrypoint

# Is the container defined? running? Evaluated per-recipe, not at parse time.
EXISTS  = $$(docker ps -aq -f name='^$(CONTAINER)$$')
RUNNING = $$(docker ps -q -f name='^$(CONTAINER)$$')

TRIVY_DB_REPO := ghcr.io/aquasecurity/trivy-db:2
TRIVY_SCAN    := trivy image --db-repository $(TRIVY_DB_REPO) \
                   --scanners vuln,secret --severity HIGH,CRITICAL \
                   --ignore-unfixed --exit-code 1

# GITHUB_TOKEN belongs only in a short-lived `-e GITHUB_TOKEN` for pi-gh/sh-gh/clone.
# Checked at parse time since every target mounting the env file would carry it;
# a bare `GITHUB_TOKEN` line would copy the host's value in.
ifeq ($(shell grep -qsE '^(GITHUB_TOKEN|GH_TOKEN)(=|$$)' '$(ENV_FILE)' && echo y),y)
$(error $(ENV_FILE) must not set GITHUB_TOKEN/GH_TOKEN -- use GH_TOKEN_CMD instead (see README))
endif

define REQUIRE_ENV_FILE
if [ ! -f "$(ENV_FILE)" ]; then \
	echo "no $(ENV_FILE) -- copy .env.example and set PI_PROVIDER/PI_MODEL and a key first" >&2; exit 1; \
fi
endef

# Refuse a WORKSPACE whose .git is a file (a worktree/submodule -- read-only
# bind-mounting it would silently disconnect it from its real repo) or is
# missing outright, then bind the host's .git/config and .git/hooks read-only.
# This stops the agent overwriting them directly, but it is NOT a host-safe
# guarantee: .git/commondir can redirect git to a config the agent DID write,
# and in-tree auto-exec files (.envrc, etc.) are untouched by this at all --
# review the diff before running anything on the host. See README "Workspace".
# Sets $$ws_mounts for the docker run/create line.
define WORKSPACE_CHECK
ws_mounts=; \
if [ -n "$(strip $(WORKSPACE))" ]; then \
	ws="$(abspath $(WORKSPACE))"; \
	if [ -f "$$ws/.git" ]; then \
		echo "WORKSPACE=$$ws: .git is a file (a worktree or submodule) -- refusing" >&2; exit 1; \
	fi; \
	if [ ! -d "$$ws/.git" ]; then \
		echo "WORKSPACE=$$ws: no .git directory -- refusing" >&2; exit 1; \
	fi; \
	mkdir -p "$$ws/.git/hooks"; \
	ws_mounts="-v $$ws:/state/work -v $$ws/.git/config:/state/work/.git/config:ro -v $$ws/.git/hooks:/state/work/.git/hooks:ro"; \
fi
endef

# Hash of the config baked into the container at create time (--env-file
# content is fixed then); a mismatch on `make up` fails instead of starting a
# container with stale config. Sets $$hash.
define CONFIG_HASH
img_id=$$(docker image inspect -f '{{.Id}}' $(IMAGE):$(TAG) 2>/dev/null || echo no-image); \
envhash=$$(sha256sum < "$(ENV_FILE)" | cut -d' ' -f1); \
hash=$$(printf '%s\n' "$$img_id" "$(NETWORK)" "$(if $(strip $(WORKSPACE)),$(abspath $(WORKSPACE)),)" "$$envhash" "$(MEMORY)" "$(CPUS)" | sha256sum | cut -d' ' -f1)
endef

# Run GH_TOKEN_CMD (a host command, possibly with pipes/quotes -- exported
# above, so it reaches `sh -c` unmangled) and trim trailing whitespace from its
# output. Required for pi-gh/sh-gh ($(1)=required); optional for clone
# ($(1)=optional), which falls back to an anonymous clone of a public repo.
# Caller pre-sets tokflag=""; this sets $$tokflag and $$GITHUB_TOKEN.
define MINT_TOKEN
if [ -n "$$GH_TOKEN_CMD" ]; then \
	GITHUB_TOKEN=$$(sh -c "$$GH_TOKEN_CMD" | sed -e 's/[[:space:]]*$$//') || { echo "GH_TOKEN_CMD failed" >&2; exit 1; }; \
	[ -n "$$GITHUB_TOKEN" ] || { echo "GH_TOKEN_CMD produced no token" >&2; exit 1; }; \
	export GITHUB_TOKEN; \
	echo "auth: minted a token via GH_TOKEN_CMD" >&2; \
	tokflag="-e GITHUB_TOKEN"; \
elif [ "$(1)" = required ]; then \
	echo "no auth: set GH_TOKEN_CMD (see README)" >&2; exit 1; \
else \
	echo "auth: none (public repo; set GH_TOKEN_CMD for a private one)" >&2; \
fi
endef

.DEFAULT_GOAL := help

.PHONY: build lint scan scan-fs clone crew-check notes export export-logs \
        up start stop restart down pi sh pi-gh sh-gh continue resume sessions exec logs ps status \
        shell run versions state-reset nuke clean help

## build: Build the image (base digests are pinned in the Dockerfile)
build:
	@uid=$$([ "$$(uname)" = Linux ] && id -u || echo 1000); \
	gid=$$([ "$$(uname)" = Linux ] && id -g || echo 1000); \
	DOCKER_BUILDKIT=1 docker build \
		--build-arg AGENT_UID=$$uid --build-arg AGENT_GID=$$gid \
		--build-arg WITH_GO=$(WITH_GO) --build-arg WITH_PYTHON=$(WITH_PYTHON) \
		$(BUILD_FLAGS) -t $(IMAGE):$(TAG) .

## lint: shellcheck the shell scripts
lint:
	shellcheck entrypoint.sh pi-home/bin/*.sh

## scan: Fail on any fixable HIGH/CRITICAL vuln or any secret in the image
scan:
	@command -v trivy >/dev/null 2>&1 || { \
		echo "trivy not found -- install it: https://aquasecurity.github.io/trivy/latest/getting-started/installation/" >&2; exit 1; }
	$(TRIVY_SCAN) $(IMAGE):$(TAG)

## scan-fs: Secret-scan this directory, and check the sanctioned secret file is locked down
# .env is skipped because it is *meant* to hold the key(s); everything else must not.
scan-fs:
	@command -v trivy >/dev/null 2>&1 || { \
		echo "trivy not found -- install it: https://aquasecurity.github.io/trivy/latest/getting-started/installation/" >&2; exit 1; }
	trivy fs --scanners secret --skip-files $(ENV_FILE) --exit-code 1 .
	@if [ -e "$(ENV_FILE)" ]; then \
		mode=$$(stat -c '%a' "$(ENV_FILE)" 2>/dev/null || stat -f '%Lp' "$(ENV_FILE)"); \
		if [ "$$mode" != "600" ]; then echo "FAIL: $(ENV_FILE) is mode $$mode, expected 600" >&2; exit 1; fi; \
		echo "ok: $(ENV_FILE) is mode 600"; \
	fi
	@if docker image inspect $(IMAGE):$(TAG) >/dev/null 2>&1; then \
		found=$$(docker run --rm --entrypoint /bin/sh $(IMAGE):$(TAG) -c 'find / -xdev -name ".env" -print -quit' 2>/dev/null); \
		if [ -n "$$found" ]; then echo "FAIL: .env found inside the built image at $$found" >&2; exit 1; fi; \
		echo "ok: no .env inside the built image"; \
	else \
		echo "skipped: $(IMAGE):$(TAG) not built -- run 'make build' first" >&2; \
	fi

## clone: Fill the volume worktree from REPO -- a URL, or an existing local directory
# A local REPO is bundled from the host's own trusted checkout and piped in over
# stdin: no env file, token or egress, and the container never sees a host path.
# A URL REPO travels through the environment, not pasted into the recipe (see `exec`).
clone: export PI_EXPERIMENTS_REPO = $(REPO)
clone:
	@test -n "$(REPO)" || { echo 'usage: make clone REPO=https://github.com/org/repo.git (or a local directory)'; exit 1; }
	@test -z "$(strip $(WORKSPACE))" || { echo "WORKSPACE=$(WORKSPACE) is set -- clone only fills the volume worktree, not a bind-mounted one; unset WORKSPACE to clone, or drop clone and use your own checkout"; exit 1; }
	@set -eu -o pipefail; \
	if [ -d "$$PI_EXPERIMENTS_REPO" ]; then \
		echo "auth: none needed (bundling the local directory over stdin)"; \
		git -C "$$PI_EXPERIMENTS_REPO" bundle create - --all | \
			docker run -i --rm $(HARDEN_BASE) --network none -v $(VOLUME):/state --entrypoint bash $(IMAGE):$(TAG) -c '\
				if [ -d /state/work/.git ]; then echo "already cloned"; exit 0; fi; \
				cat > /tmp/x.bundle && \
				git clone /tmp/x.bundle /state/work && \
				git -C /state/work remote remove origin && \
				rm -f /tmp/x.bundle && \
				git -C /state/work log --oneline -1'; \
	else \
		tokflag=""; $(call MINT_TOKEN,optional); \
		docker run $(RUN_FLAGS_BATCH) -e PI_EXPERIMENTS_REPO $$tokflag $(IMAGE):$(TAG) bash -c '\
			if [ -d /state/work/.git ]; then echo "already cloned:"; git -C /state/work remote -v; \
			else git clone "$$PI_EXPERIMENTS_REPO" /state/work && git -C /state/work log --oneline -1; fi'; \
	fi

## crew-check: Prove pi loaded the crew extension and resolves every subagent
crew-check:
	@set -eu; $(WORKSPACE_CHECK); \
	docker run $(RUN_FLAGS_BATCH) $$ws_mounts $(IMAGE):$(TAG) bash -c '\
		pi --version && \
		ls $$PI_CODING_AGENT_DIR/agents/ && \
		echo "--- installed package ---" && \
		cat $$PI_CODING_AGENT_DIR/npm/node_modules/@melihmucuk/pi-crew/package.json | jq -r .version'

## notes: Print the notes ledger index from the volume
notes:
	@docker run $(RUN_FLAGS_BATCH) $(IMAGE):$(TAG) bash -c 'cat $$NOTES_ROOT/INDEX.md'

## export: Write the worktree's branches to a git bundle for review on the host
# A bundle carries no config/hooks, unlike a bind mount -- safe to fetch straight
# into a repo you care about. No env file needed and no egress (--network none).
export:
	@test -z "$(strip $(WORKSPACE))" || { echo "WORKSPACE=$(WORKSPACE) is set -- nothing to export, that worktree is already your host checkout"; exit 1; }
	@set -eu -o pipefail; \
	docker run --rm $(HARDEN_BASE) --network none -v $(VOLUME):/state --entrypoint git $(IMAGE):$(TAG) \
		-C /state/work bundle create - --branches > "$(OUT).tmp" || { rm -f "$(OUT).tmp"; exit 1; }; \
	mv "$(OUT).tmp" "$(OUT)"; \
	echo "wrote $(OUT) -- on the host: git -c transfer.fsckObjects=true fetch $(OUT) 'refs/heads/*:refs/remotes/pi/*'"

## export-logs: Tar every session (principal + subagents, JSONL + HTML) and the notes ledger
# Transcripts hold everything the agent read or printed, hence 0600 and a warning.
export-logs:
	@set -eu -o pipefail; \
	docker run --rm $(HARDEN_BASE) --network none -v $(VOLUME):/state --entrypoint bash $(IMAGE):$(TAG) -c '\
		set -eu; out=/tmp/pi-logs; mkdir -p $$out/html; \
		for f in /state/pi-home/agent/sessions/*/*.jsonl; do [ -e "$$f" ] || continue; \
			pi --export "$$f" "$$out/html/$$(basename "$$f" .jsonl).html" >/dev/null 2>&1 || echo "skipped $$f" >&2; done; \
		cp -r /state/pi-home/agent/sessions $$out/sessions; cp -r /state/pi-notes $$out/notes; \
		tar -C /tmp -czf - pi-logs' > "$(LOGS_OUT).tmp" || { rm -f "$(LOGS_OUT).tmp"; exit 1; }; \
	chmod 600 "$(LOGS_OUT).tmp"; mv "$(LOGS_OUT).tmp" "$(LOGS_OUT)"; \
	echo "wrote $(LOGS_OUT) -- full transcripts, may contain secrets the agent saw; don't share or commit it"

# ===========================================================================
# Container lifecycle
# ===========================================================================

## up: Create and start the managed container in the background
up:
	@$(REQUIRE_ENV_FILE)
	@set -eu; $(WORKSPACE_CHECK); $(CONFIG_HASH); \
	if [ -n "$(EXISTS)" ]; then \
		existing=$$(docker inspect -f '{{ index .Config.Labels "pi-experiments.config-hash" }}' $(CONTAINER) 2>/dev/null || echo ""); \
		if [ "$$existing" != "$$hash" ]; then \
			echo "config changed since this container was created -- run: make down && make up" >&2; exit 1; \
		fi; \
		echo "$(CONTAINER) already exists; starting it"; docker start $(CONTAINER) >/dev/null; \
	else \
		docker run $(DAEMON_FLAGS) $$ws_mounts --label pi-experiments.config-hash=$$hash $(IMAGE):$(TAG) sleep infinity >/dev/null; \
		echo "started $(CONTAINER)"; \
	fi
	@$(MAKE) --no-print-directory status

## start: Start the managed container again after `make stop`
start:
	@if [ -z "$(EXISTS)" ]; then echo "no container named $(CONTAINER); run 'make up'"; exit 1; fi
	@docker start $(CONTAINER) >/dev/null && echo "started $(CONTAINER)"

## stop: Stop the managed container (state volume and container are kept)
stop:
	@if [ -z "$(RUNNING)" ]; then echo "$(CONTAINER) is not running"; else \
		docker stop $(CONTAINER) >/dev/null && echo "stopped $(CONTAINER)"; fi

## restart: Stop and start the managed container
restart:
	@$(MAKE) --no-print-directory stop
	@$(MAKE) --no-print-directory start

## down: Stop and remove the managed container (the state volume survives)
down:
	@if [ -z "$(EXISTS)" ]; then echo "no container named $(CONTAINER)"; else \
		docker rm -f $(CONTAINER) >/dev/null && echo "removed $(CONTAINER)"; fi

## pi: Attach a pi session inside the managed container (starts it if needed)
pi:
	@if [ -z "$(RUNNING)" ]; then $(MAKE) --no-print-directory up >/dev/null || exit 1; fi
	docker exec -it -w /state/work $(CONTAINER) $(EXEC_ENTRY) pi $(PI_ARGS)

## sh: Interactive shell inside the managed container (starts it if needed)
sh:
	@if [ -z "$(RUNNING)" ]; then $(MAKE) --no-print-directory up >/dev/null || exit 1; fi
	docker exec -it -w /state/work $(CONTAINER) $(EXEC_ENTRY) bash

## pi-gh: Like `pi`, but with a freshly minted GitHub token in the session
pi-gh:
	@if [ -z "$(RUNNING)" ]; then $(MAKE) --no-print-directory up >/dev/null || exit 1; fi
	@set -eu -o pipefail; tokflag=""; $(call MINT_TOKEN,required); \
	exec docker exec -it $$tokflag -w /state/work $(CONTAINER) $(EXEC_ENTRY) pi $(PI_ARGS)

## sh-gh: Like `sh`, but with a freshly minted GitHub token in the session
sh-gh:
	@if [ -z "$(RUNNING)" ]; then $(MAKE) --no-print-directory up >/dev/null || exit 1; fi
	@set -eu -o pipefail; tokflag=""; $(call MINT_TOKEN,required); \
	exec docker exec -it $$tokflag -w /state/work $(CONTAINER) $(EXEC_ENTRY) bash

## continue: Reopen the most recent pi session in the worktree
continue:
	@$(MAKE) --no-print-directory pi PI_ARGS=--continue

## resume: Pick a past pi session from a list and reopen it
resume:
	@$(MAKE) --no-print-directory pi PI_ARGS=--resume

## sessions: List saved pi sessions on the volume, newest first
sessions:
	@if [ -z "$(RUNNING)" ]; then $(MAKE) --no-print-directory up >/dev/null || exit 1; fi
	@docker exec $(CONTAINER) sh -c 'd=$$PI_CODING_AGENT_DIR/sessions/--state-work--; \
		ls -t $$d/*.jsonl 2>/dev/null | head -20 | while read f; do \
			printf "%s  %8sB  %s\n" "$$(date -u -r $$f +%Y-%m-%dT%H:%M:%SZ)" "$$(wc -c <$$f)" "$$(basename $$f)"; \
		done' || echo "no sessions yet"

## exec: Run one command in the managed container -- make exec CMD="git status"
# CMD travels through the environment rather than being pasted into the recipe:
# interpolating it would break on the first double quote it contains. Write $$
# for a literal dollar, e.g. CMD='echo $$HOME'.
exec: export PI_EXPERIMENTS_CMD = $(value CMD)
exec:
ifeq ($(strip $(CMD)),)
	@echo 'usage: make exec CMD="git -C /state/work status"'; exit 1
else
	@if [ -z "$(RUNNING)" ]; then $(MAKE) --no-print-directory up >/dev/null || exit 1; fi
	@docker exec -e PI_EXPERIMENTS_CMD -w /state/work $(CONTAINER) $(EXEC_ENTRY) \
		bash -c 'eval "$$PI_EXPERIMENTS_CMD"'
endif

## logs: Tail the managed container's logs (make logs FOLLOW=1 to stream)
logs:
	@if [ -z "$(EXISTS)" ]; then echo "no container named $(CONTAINER)"; exit 1; fi
	@docker logs $(if $(FOLLOW),-f,) --tail 200 $(CONTAINER)

## ps: Show the managed container
ps:
	@docker ps -a -f name='^$(CONTAINER)$$' \
		--format 'table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Size}}'

## status: One-screen view of image, container, volume, worktree and provider config
status:
	@echo "image      $(IMAGE):$(TAG)  $$(docker images -q $(IMAGE):$(TAG) >/dev/null 2>&1 && docker images $(IMAGE):$(TAG) --format '{{.ID}} {{.Size}}' || echo 'NOT BUILT')"
	@echo "container  $(CONTAINER)  $$(docker ps -a -f name='^$(CONTAINER)$$' --format '{{.Status}}' || true)$$([ -z "$(EXISTS)" ] && echo 'not created' || true)"
	@echo "volume     $(VOLUME)  $$(docker volume inspect $(VOLUME) --format '{{.Mountpoint}}' 2>/dev/null || echo 'not created')"
	@echo "env file   $(ENV_FILE)  $$([ -f "$(ENV_FILE)" ] && (stat -c 'mode %a' "$(ENV_FILE)" 2>/dev/null || stat -f 'mode %Lp' "$(ENV_FILE)") || echo MISSING)"
	@if [ -n "$(RUNNING)" ]; then \
		docker exec $(CONTAINER) $(EXEC_ENTRY) bash -c '\
			echo "worktree   $$(git -C /state/work rev-parse --abbrev-ref HEAD 2>/dev/null || echo "empty - run make clone")"; \
			provider=$$(jq -r .defaultProvider "$$PI_CODING_AGENT_DIR/settings.json"); \
			model=$$(jq -r .defaultModel "$$PI_CODING_AGENT_DIR/settings.json"); \
			keyref=$$(jq -r ".providers[\"$$provider\"].apiKey // empty" "$$PI_CODING_AGENT_DIR/models.json"); \
			keyvar=$${keyref#\$$}; \
			echo "model      $$provider/$$model"; \
			if [ -n "$$keyvar" ] && [ -n "$$(printenv "$$keyvar")" ]; then echo "api key    present (value not shown)"; \
			else echo "api key    ABSENT ($${keyvar:-provider key unresolved})"; fi; \
			echo "notes      $$(find "$$NOTES_ROOT" -name "*.md" 2>/dev/null | wc -l) markdown files"'; \
	fi

# ===========================================================================
# One-shot containers (--rm; nothing survives the command)
# ===========================================================================

## shell: One-shot throwaway shell (prefer `make sh` for the managed container)
shell:
	@$(REQUIRE_ENV_FILE)
	@set -eu; $(WORKSPACE_CHECK); \
	docker run $(RUN_FLAGS) $$ws_mounts $(IMAGE):$(TAG) bash

## run: One-shot -- interactive pi, or headless with TASK="..." (prefer `make pi`)
# TASK travels through the environment, not interpolated into the recipe --
# same reasoning as CMD in `exec` (quotes in TASK would otherwise break the line).
run: export PI_EXPERIMENTS_TASK = $(value TASK)
run:
	@$(REQUIRE_ENV_FILE)
	@set -eu; $(WORKSPACE_CHECK); \
	if [ -n "$${PI_EXPERIMENTS_TASK:-}" ]; then \
		docker run $(RUN_FLAGS_BATCH) $$ws_mounts -e PI_EXPERIMENTS_TASK $(IMAGE):$(TAG) \
			bash -c '[ "$${PI_MODE:-solo}" = solo ] || { echo "headless run is solo-only: pi -p exits after one turn and aborts pi-crew subagents -- use make pi" >&2; exit 1; }; \
				exec pi -p "$$PI_EXPERIMENTS_TASK"'; \
	else \
		docker run $(RUN_FLAGS) $$ws_mounts $(IMAGE):$(TAG) pi; \
	fi

## versions: Show what the image actually contains
versions:
	@docker run $(RUN_FLAGS_BATCH) $(IMAGE):$(TAG) bash -c '\
		echo "pi      $$(pi --version 2>/dev/null || echo unknown)"; \
		echo "node    $$(node --version)"; \
		echo "git     $$(git --version)"; \
		echo "go      $$(go version 2>/dev/null || echo "not installed (WITH_GO=0)")"; \
		echo "uv      $$(uv --version 2>/dev/null || echo "not installed (WITH_PYTHON=0)")"; \
		echo "python  $$(python3 --version 2>/dev/null || echo "not installed (WITH_PYTHON=0)")"; \
		echo "crew    $$(jq -r .version $$PI_CODING_AGENT_DIR/npm/node_modules/@melihmucuk/pi-crew/package.json 2>/dev/null || echo MISSING)"; \
		provider=$$(jq -r .defaultProvider $$PI_CODING_AGENT_DIR/settings.json); \
		model=$$(jq -r .defaultModel $$PI_CODING_AGENT_DIR/settings.json); \
		echo "model   $$provider/$$model"; \
		echo "mode    $${PI_MODE:-solo} (packages: $$(jq -c .packages $$PI_CODING_AGENT_DIR/settings.json))"; \
		printf "thinking principal=%s" "$$(jq -r ".defaultThinkingLevel // \"pi-default\"" $$PI_CODING_AGENT_DIR/settings.json)"; \
		if [ "$${PI_MODE:-solo}" = crew ]; then for f in $$PI_CODING_AGENT_DIR/agents/*.md; do a=$$(basename "$$f" .md); \
			t=$$(jq -r --arg a "$$a" ".agents[\$$a].thinking // empty" $$PI_CODING_AGENT_DIR/pi-crew.json); \
			printf " %s=%s" "$$a" "$${t:-$$(sed -n "s/^thinking: *//p" "$$f")}"; done; fi; echo; \
		keyref=$$(jq -r ".providers[\"$$provider\"].apiKey // empty" $$PI_CODING_AGENT_DIR/models.json); \
		keyvar=$${keyref#\$$}; \
		if [ -n "$$keyvar" ] && [ -n "$$(printenv "$$keyvar")" ]; then echo "key     present (value not shown)"; \
		else echo "key     ABSENT"; fi; \
		echo "user    $$(id)"'

## state-reset: Delete the state volume (pi config, caches, git identity)
state-reset:
	@if [ -n "$(EXISTS)" ]; then \
		echo "$(CONTAINER) still holds $(VOLUME); run 'make down' first"; exit 1; fi
	-docker volume rm $(VOLUME)

## nuke: Remove container, state volume and image (destroys notes and sessions)
nuke:
	@$(MAKE) --no-print-directory down
	@$(MAKE) --no-print-directory state-reset
	@$(MAKE) --no-print-directory clean

## clean: Remove the image
clean:
	-docker rmi $(IMAGE):$(TAG)

## help: Show available targets
help:
	@echo "Usage: make [target]"
	@echo ""
	@sed -n 's/^## //p' $(MAKEFILE_LIST) | column -t -s ':' | sed 's/^/  /'
