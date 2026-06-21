#!/usr/bin/env bash
# pi sandbox driver. Verbs:
#   once <dir> [task]  one-shot (headless if task given, else interactive TUI)
#   up   <dir>         start a persistent detached container on <dir>
#   chat               attach an interactive pi chat to the running container
#   sh                 open a shell inside the running container
#   down               stop & remove the persistent container
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME="${PI_NAME:-pi-box}"
IMAGE="${PI_IMAGE:-pi-sandbox}"
PROVIDER="${PROVIDER:-llmbase}"
MODEL="${MODEL:-minimax/minimax-m3}"
THINK="${THINK:-medium}"

[[ -f "$SCRIPT_DIR/.env" ]] && { set -a; source "$SCRIPT_DIR/.env"; set +a; }
PI_FLAGS=( --provider "$PROVIDER" --model "$MODEL" --thinking "$THINK" )

need_key() { : "${LLMBASE_API_KEY:?set LLMBASE_API_KEY in $SCRIPT_DIR/.env}"; }

# Populate COMMON[] (mounts, env, hardening) for project dir $1. uid/gid match
# keeps host file ownership sane on bind-mounted writes.
build_common() {
  local project; project="$(realpath "$1")"
  COMMON=(
    --user "$(id -u):$(id -g)"
    -e HOME=/home/node
    -e LLMBASE_API_KEY                 # pi interpolates $LLMBASE_API_KEY in models.json
    -v "$project:/workspace"
    -v pi-agent-home:/home/node/.pi/agent
    -v "$SCRIPT_DIR/AGENTS.md:/home/node/.pi/agent/AGENTS.md:ro"
    -v "$SCRIPT_DIR/models.json:/home/node/.pi/agent/models.json:ro"
    --cap-drop ALL
    --security-opt no-new-privileges
    --pids-limit 512
    --memory 4g
  )
}

CMD="${1:-}"; shift || true
case "$CMD" in
  once)
    DIR="${1:?usage: run.sh once <dir> [task]}"; TASK="${2:-}"
    need_key; build_common "$DIR"
    if [[ -n "$TASK" ]]; then
      exec docker run --rm -it "${COMMON[@]}" "$IMAGE" "${PI_FLAGS[@]}" -p "$TASK"
    else
      exec docker run --rm -it "${COMMON[@]}" "$IMAGE" "${PI_FLAGS[@]}"
    fi
    ;;
  up)
    DIR="${1:?usage: run.sh up <dir>}"
    need_key; build_common "$DIR"
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    # block on sleep so the container outlives any single pi session
    docker run -d --name "$NAME" "${COMMON[@]}" --entrypoint sleep "$IMAGE" infinity >/dev/null
    echo "'$NAME' up on $(realpath "$DIR"). chat: make chat | shell: make sh | stop: make down"
    ;;
  chat)
    exec docker exec -it -w /workspace "$NAME" pi "${PI_FLAGS[@]}"
    ;;
  sh)
    exec docker exec -it -w /workspace "$NAME" bash
    ;;
  down)
    docker rm -f "$NAME" >/dev/null 2>&1 && echo "removed '$NAME'" || echo "no '$NAME' running"
    ;;
  *)
    echo "usage: run.sh {once <dir> [task]|up <dir>|chat|sh|down}"; exit 1 ;;
esac
