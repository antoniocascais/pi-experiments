#!/bin/sh
# devsec-tier1.sh -- cheap, deterministic secret/scope/destructive-git checks.
# Worktree mode: the implementer never commits, so this diffs BASE against the
# worktree (not a commit range), plus untracked file content.
#
# Usage:  devsec-tier1.sh [BASE] [scope-path ...]   (BASE defaults to HEAD)
# Exit:   0 clean, 1 findings, 2 usage/environment error.
# Never prints a secret value: matches are reported as file:line only.

set -u

BASE="${1:-HEAD}"
[ $# -ge 1 ] && shift
SCOPE="$*"
findings=0
nl='
'

note()  { echo "FINDING  $*"; findings=$((findings + 1)); }
clean() { echo "clean    $*"; }

git rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repository" >&2; exit 2; }
git rev-parse --verify --quiet "$BASE" >/dev/null || { echo "bad base: $BASE" >&2; exit 2; }
cd "$(git rev-parse --show-toplevel)" || exit 2  # anchor: paths below are cwd-relative

TRACKED=$(git diff --name-only "$BASE")
UNTRACKED=$(git ls-files --others --exclude-standard)
CHANGED=$(printf '%s\n%s\n' "$TRACKED" "$UNTRACKED" | sed '/^$/d' | sort -u)
[ -n "$CHANGED" ] || { echo "no files changed since $BASE"; exit 0; }

echo "== devsec tier 1 -- $BASE..worktree ($(printf '%s\n' "$CHANGED" | wc -l) files)"

# Added lines (tracked) + full content of untracked files, both prefixed "+" so
# the same patterns match either. Only ever used as a grep/case haystack, never
# echoed as a whole.
ADDED=$(git diff -U0 "$BASE" -- . | grep '^+' | grep -v '^+++')
oldifs=$IFS; IFS=$nl
for f in $UNTRACKED; do
  [ -f "$f" ] || continue
  ADDED="$ADDED
$(sed 's/^/+/' "$f" 2>/dev/null)"
done
IFS=$oldifs

# --- 1. secret-shaped strings added by this range -----------------------------
PATTERNS='(gh[pousr]_[A-Za-z0-9]{16,})|(sk-[A-Za-z0-9_-]{16,})|(AKIA[0-9A-Z]{16})|(eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})|((api[_-]?key|secret|passwd|password|token|bearer)["'"'"'[:space:]:=]+[^[:space:]"'"'"',]{16,})'
if printf '%s\n' "$ADDED" | grep -Eqi "$PATTERNS"; then
  oldifs=$IFS; IFS=$nl
  for f in $CHANGED; do
    if printf '%s\n' "$UNTRACKED" | grep -qxF "$f"; then
      # grep -c exits 1 on zero matches while still printing "0" -- capture it
      # directly, don't chain with `||` or a fallback command's output doubles up.
      hits=0
      [ -f "$f" ] && hits=$(grep -Eci "$PATTERNS" "$f" 2>/dev/null)
    else
      hits=$(git diff -U0 "$BASE" -- "$f" 2>/dev/null | grep '^+' | grep -v '^+++' | grep -Eci "$PATTERNS")
    fi
    [ "${hits:-0}" -gt 0 ] && note "secret-shaped string added in $f ($hits line(s)) -- inspect by hand, do not paste the value"
  done
  IFS=$oldifs
else
  clean "no secret-shaped strings added"
fi

# --- 2. a real secret value reaching the diff ---------------------------------
# Covers .env* files at the repo root AND sandbox secrets already in the
# environment (every *_API_KEY, GITHUB_TOKEN). Matched with `case`, a shell
# builtin, so the value is never passed to an external command's argv.
envhit=0
check_val() {
  val=$2
  [ ${#val} -ge 12 ] || return 0
  case "$ADDED" in
    *"$val"*)
      note "value of \$$1 appears since $BASE -- ROTATE THE CREDENTIAL, this is already in history if pushed"
      envhit=1
      ;;
  esac
}

for envf in ./.env*; do
  [ -f "$envf" ] || continue
  case "$envf" in *.example) continue ;; esac
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    name=${line%%=*}
    val=${line#*=}
    val=$(printf '%s' "$val" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
    check_val "$name" "$val"
  done < "$envf"
done

for name in $(env | grep -E '^[A-Za-z_][A-Za-z0-9_]*_API_KEY=|^GITHUB_TOKEN=' | cut -d= -f1); do
  eval "val=\${$name}"
  check_val "$name" "$val"
done

[ "$envhit" -eq 0 ] && clean "no known secret value appears in the diff"

# --- 3. credential-bearing files touched --------------------------------------
CREDPAT='(^|/)\.env|\.pem$|\.p12$|\.pfx$|(^|/)id_(rsa|dsa|ecdsa|ed25519)$|\.key$|(^|/)\.netrc$|(^|/)\.npmrc$|(^|/)credentials$'
if printf '%s\n' "$CHANGED" | grep -Eq "$CREDPAT"; then
  printf '%s\n' "$CHANGED" | grep -E "$CREDPAT" | while read -r f; do echo "FINDING  credential-bearing file in the diff: $f"; done
  findings=$((findings + 1))
else
  clean "no credential-bearing file touched"
fi

# --- 4. scope escape ----------------------------------------------------------
# $CHANGED is newline-separated (may contain spaces in a path); $SCOPE is the
# space-separated scope args -- each loop needs its own IFS, swapped in and out.
if [ -n "$SCOPE" ]; then
  out=0
  oldifs=$IFS; IFS=$nl
  for f in $CHANGED; do
    ok=0
    IFS=' '
    for s in $SCOPE; do
      case "$f" in "$s"|"$s"/*) ok=1; break ;; esac
    done
    IFS=$nl
    [ "$ok" -eq 0 ] && { note "outside declared scope: $f"; out=1; }
  done
  IFS=$oldifs
  [ "$out" -eq 0 ] && clean "every changed file is inside the declared scope"
else
  echo "skipped  scope check -- no scope paths given"
fi

# --- 5. dependency and lockfile movement --------------------------------------
DEPPAT='(^|/)(uv\.lock|poetry\.lock|package-lock\.json|pnpm-lock\.yaml|yarn\.lock|Cargo\.lock|go\.sum|requirements[^/]*\.txt|pyproject\.toml|package\.json|go\.mod|Cargo\.toml)$'
if printf '%s\n' "$CHANGED" | grep -Eq "$DEPPAT"; then
  printf '%s\n' "$CHANGED" | grep -E "$DEPPAT" | while read -r f; do echo "FINDING  dependency/lockfile changed: $f -- must be sanctioned by the task"; done
  findings=$((findings + 1))
else
  clean "no dependency or lockfile movement"
fi

# --- 6. destructive git -------------------------------------------------------
# Scoped to reflog entries since BASE's commit -- the whole reflog also holds
# routine `git stash` entries, which trip the same "reset:" pattern and would
# otherwise block forever. `reset: moving to HEAD` (no target change) is what a
# stash pop/apply writes internally and is excluded; any other reset target
# still matches.
SINCE=$(git log -1 --format=%cI "$BASE" 2>/dev/null)
if [ -n "$SINCE" ] && git reflog --since="$SINCE" --date=iso 2>/dev/null \
     | grep -v 'reset: moving to HEAD$' \
     | grep -Eqi 'reset:|filter-repo|rebase \(|updating HEAD.*forced|forced-update'; then
  note "reflog since $BASE shows a reset/rebase/forced update -- confirm no published history was rewritten"
else
  clean "reflog since $BASE shows no reset, rebase or forced update"
fi
if [ -n "$(git log --merges "$BASE"..HEAD 2>/dev/null)" ]; then
  note "history in $BASE..HEAD is not linear (merge commits present)"
else
  clean "history in $BASE..HEAD is linear"
fi
if ! git merge-base --is-ancestor "$BASE" HEAD 2>/dev/null; then
  note "$BASE is not an ancestor of HEAD -- history was rewritten"
else
  clean "$BASE is an ancestor of HEAD"
fi

echo "== tier 1: $findings finding(s)"
[ "$findings" -eq 0 ] && exit 0 || exit 1
