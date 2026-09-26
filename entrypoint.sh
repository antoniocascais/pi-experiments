#!/bin/sh
# Re-applies image-owned pi config over the state volume on every run: settings.json,
# models.json, pi-crew.json, AGENTS.md, agents/, extensions/ and bin/ are always
# image-controlled here; sessions/ and the baked npm/ install are the only things
# on the volume this script does not overwrite.
set -eu

PI_BUILD_HOME=${PI_BUILD_HOME:-/opt/pi-home}
NOTES_SKEL=/opt/pi-notes-skel

# --- validate configuration --------------------------------------------------
# --env-file keeps quotes literally; a quoted key would otherwise surface as a 401 mid-session.
quoted=$(env | sed -n "s/^\([A-Za-z_][A-Za-z0-9_]*\)=[\"'].*/\1/p" | tr '\n' ' ')
if [ -n "$quoted" ]; then
  echo "pi-experiments: remove the quotes around: ${quoted}(--env-file passes them through literally)" >&2; exit 1
fi
PI_MODE=${PI_MODE:-solo}
case "$PI_MODE" in
  solo|crew) ;;
  *) echo "pi-experiments: PI_MODE must be 'solo' or 'crew' (got '$PI_MODE')" >&2; exit 1 ;;
esac
: "${PI_PROVIDER:?pi-experiments: PI_PROVIDER is required (see models.json)}"
: "${PI_MODEL:?pi-experiments: PI_MODEL is required (see models.json)}"
case "${PI_THINKING:-}" in
  ''|off|minimal|low|medium|high|xhigh|max) ;;
  *) echo "pi-experiments: PI_THINKING must be off|minimal|low|medium|high|xhigh|max (got '$PI_THINKING')" >&2; exit 1 ;;
esac

# --- home and caches ----------------------------------------------------------
for d in \
  "${HOME}" \
  "${XDG_CONFIG_HOME}" \
  "${XDG_DATA_HOME}" \
  "${XDG_STATE_HOME}" \
  "${XDG_CACHE_HOME}" \
  "${UV_CACHE_DIR}" \
  "${NPM_CONFIG_CACHE}" \
  "/state/work"
do
  mkdir -p "${d}"
done

# --- pi config home: overwritten every run -----------------------------------
mkdir -p "${PI_CODING_AGENT_DIR}"

# The baked npm install is seeded once, never overwritten: pi only re-resolves
# it when the path is missing or version-mismatched, and there is no package
# manager left in the image to redo that work anyway.
if [ ! -d "${PI_CODING_AGENT_DIR}/npm" ] && [ -d "${PI_BUILD_HOME}/agent/npm" ]; then
  cp -a "${PI_BUILD_HOME}/agent/npm" "${PI_CODING_AGENT_DIR}/npm"
fi

for f in settings.json models.json pi-crew.json; do
  [ -e "${PI_BUILD_HOME}/agent/${f}" ] && cp -a "${PI_BUILD_HOME}/agent/${f}" "${PI_CODING_AGENT_DIR}/${f}"
done

src_agents_md="${PI_BUILD_HOME}/agent/AGENTS.${PI_MODE}.md"
if [ ! -e "${src_agents_md}" ]; then
  echo "pi-experiments: missing ${src_agents_md}" >&2
  exit 1
fi
cp -a "${src_agents_md}" "${PI_CODING_AGENT_DIR}/AGENTS.md"

for d in agents extensions bin; do
  if [ -d "${PI_BUILD_HOME}/agent/${d}" ]; then
    # Skip the rm+cp when content already matches: an unconditional refresh
    # races a pi session already running in this container reading these files.
    if ! diff -rq "${PI_BUILD_HOME}/agent/${d}" "${PI_CODING_AGENT_DIR}/${d}" >/dev/null 2>&1; then
      rm -rf "${PI_CODING_AGENT_DIR:?}/${d}"
      cp -a "${PI_BUILD_HOME}/agent/${d}" "${PI_CODING_AGENT_DIR}/${d}"
    fi
  fi
done
# A volume copy can lose the executable bit; devsec-tier1.sh is invoked directly.
[ -d "${PI_CODING_AGENT_DIR}/bin" ] && chmod -R 0755 "${PI_CODING_AGENT_DIR}/bin"

# --- validate provider/model against the config just installed ---------------
MODELS_FILE="${PI_CODING_AGENT_DIR}/models.json"
SETTINGS_FILE="${PI_CODING_AGENT_DIR}/settings.json"
PICREW_FILE="${PI_CODING_AGENT_DIR}/pi-crew.json"

if ! jq -e --arg p "$PI_PROVIDER" '.providers[$p]' "$MODELS_FILE" >/dev/null; then
  echo "pi-experiments: provider '$PI_PROVIDER' is not in models.json" >&2
  exit 1
fi
if ! jq -e --arg p "$PI_PROVIDER" --arg m "$PI_MODEL" \
      '.providers[$p].models[]? | select(.id == $m)' "$MODELS_FILE" >/dev/null; then
  echo "pi-experiments: model '$PI_MODEL' is not offered by provider '$PI_PROVIDER' in models.json" >&2
  exit 1
fi

# --- patch settings.json for this run -----------------------------------------
TOOLS_SOLO='["read","grep","find","ls","bash","edit","write"]'
TOOLS_CREW='["read","grep","find","ls","bash","edit"]'
[ "$PI_MODE" = "solo" ] && tools="$TOOLS_SOLO" || tools="$TOOLS_CREW"

tmp=$(mktemp "$(dirname "$SETTINGS_FILE")/.tmp.XXXXXX")
jq --arg provider "$PI_PROVIDER" --arg model "$PI_MODEL" --arg mode "$PI_MODE" --argjson tools "$tools" \
  '.defaultProvider = $provider | .defaultModel = $model | .defaultTools = $tools
   | if $mode == "solo" then .packages = [] else . end' \
  "$SETTINGS_FILE" > "$tmp"
mv "$tmp" "$SETTINGS_FILE"

if [ -n "${PI_THINKING:-}" ]; then
  tmp=$(mktemp "$(dirname "$SETTINGS_FILE")/.tmp.XXXXXX")
  jq --arg t "$PI_THINKING" '.defaultThinkingLevel = $t' "$SETTINGS_FILE" > "$tmp"
  mv "$tmp" "$SETTINGS_FILE"
fi

# --- patch pi-crew.json for this run ------------------------------------------
if [ -e "$PICREW_FILE" ]; then
  tmp=$(mktemp "$(dirname "$PICREW_FILE")/.tmp.XXXXXX")
  jq --arg model "${PI_PROVIDER}/${PI_MODEL}" '(.agents[]?) |= (.model = $model)' "$PICREW_FILE" > "$tmp"
  mv "$tmp" "$PICREW_FILE"
  if [ -n "${PI_THINKING:-}" ]; then
    tmp=$(mktemp "$(dirname "$PICREW_FILE")/.tmp.XXXXXX")
    jq --arg th "$PI_THINKING" '(.agents[]?) |= (.thinking = $th)' "$PICREW_FILE" > "$tmp"
    mv "$tmp" "$PICREW_FILE"
  fi
fi

# --- sanitise only the api key the selected provider needs --------------------
# docker --env-file does no shell parsing: KEY="value" arrives with the quotes
# as part of the value, and a trailing CR survives a CRLF-edited file. Both
# produce a 401 that looks exactly like a wrong key.
# Only "$NAME" is a variable reference; a literal key (or garbage) must not
# reach eval/export below.
key_ref=$(jq -r --arg p "$PI_PROVIDER" '.providers[$p].apiKey // empty' "$MODELS_FILE")
key_var=""
case "$key_ref" in
  \$[A-Za-z_]*)
    candidate=${key_ref#\$}
    case "$candidate" in
      *[!A-Za-z0-9_]*) ;;
      *) key_var="$candidate" ;;
    esac
    ;;
esac
if [ -n "$key_ref" ] && [ -z "$key_var" ]; then
  echo "pi-experiments: warning: apiKey for provider '$PI_PROVIDER' in models.json is not a \$VAR reference" >&2
fi
if [ -n "$key_var" ]; then
  val=$(printenv "$key_var" 2>/dev/null || true)
  if [ -n "$val" ]; then
    val=$(printf '%s' "$val" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/")
    eval "$key_var=\$val"
    # shellcheck disable=SC2163  # exporting by dynamic name, not the literal var key_var
    export "$key_var"
  else
    echo "pi-experiments: warning: $key_var is empty (provider '$PI_PROVIDER' needs it)" >&2
  fi
fi

# --- notes ledger, seeded once -------------------------------------------------
if [ ! -e "${NOTES_ROOT}/INDEX.md" ] && [ -d "${NOTES_SKEL}" ]; then
  mkdir -p "${NOTES_ROOT}"
  cp -a "${NOTES_SKEL}/." "${NOTES_ROOT}/"
  find "${NOTES_ROOT}" -name .gitkeep -delete
fi

# --- git ------------------------------------------------------------------------
# No ssh client is installed, so force HTTPS to keep a git@github.com: remote
# working. --add + an existence check keeps this idempotent across the many
# re-runs this entrypoint sees (every exec/pi/sh) -- --add alone would duplicate
# the rewrite every run and eventually shadow the first one.
for url in "git@github.com:" "ssh://git@github.com/"; do
  git config --global --get-all url."https://github.com/".insteadOf 2>/dev/null | grep -qxF "$url" \
    || git config --global --add url."https://github.com/".insteadOf "$url"
done

# The worktree may be a bind-mounted host tree not owned by this uid; either
# way pi should not trip over git's ownership check.
git config --global --get-all safe.directory 2>/dev/null | grep -qxF /state/work \
  || git config --global --add safe.directory /state/work

# Without an identity the agent invents one itself; GIT_AUTHOR_*/GIT_COMMITTER_* still win.
git config --global user.name >/dev/null || git config --global user.name pi-agent
git config --global user.email >/dev/null || git config --global user.email pi-agent@localhost

# Scoped to github.com only. Reads GITHUB_TOKEN at call time and answers only
# `get`, so a tokenless exec prints nothing instead of an empty password, and
# the token never touches .git/config, the remote URL or the volume.
# shellcheck disable=SC2016  # single-quoted on purpose: git runs this script itself, later
git config --global credential.https://github.com.helper \
  '!f() { [ "$1" = get ] && [ -n "${GITHUB_TOKEN:-}" ] && { echo username=x-access-token; echo "password=$GITHUB_TOKEN"; } || true; }; f'
# Never block on an interactive credential prompt; fail fast instead.
export GIT_TERMINAL_PROMPT=0

exec "$@"
