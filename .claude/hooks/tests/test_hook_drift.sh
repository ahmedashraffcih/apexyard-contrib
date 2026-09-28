#!/bin/bash
# Tests for _lib-hook-drift.sh (me2resh/apexyard#1449).
#
# The helper is advisory, so the cases that matter most are the silent ones:
# a false "your hook is stale" note on a current fork, or on an adopter's own
# customised hook, is the noise this feature exists to avoid.

set -u

LIB_SRC="$(cd "$(dirname "$0")/.." && pwd)/_lib-hook-drift.sh"
if [ ! -f "$LIB_SRC" ]; then
  echo "FAIL: lib not found at $LIB_SRC" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$LIB_SRC"

PASS=0
FAIL=0

ok()  { echo "PASS [$1]"; PASS=$((PASS+1)); }
bad() { echo "FAIL [$1]: $2" >&2; FAIL=$((FAIL+1)); }

assert_silent() {
  local label="$1" out="$2"
  if [ -z "$out" ]; then ok "$label"; else bad "$label" "expected no output, got: $out"; fi
}

assert_mentions() {
  local label="$1" out="$2" needle="$3"
  case "$out" in
    *"$needle"*) ok "$label" ;;
    *) bad "$label" "expected output mentioning '$needle', got: ${out:-<empty>}" ;;
  esac
}

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

git_quiet() { git -C "$1" "${@:2}" >/dev/null 2>&1; }

# Build an "upstream" repo with a hook, and a "fork" cloned from it.
UP="$TMP/upstream"
mkdir -p "$UP/.claude/hooks"
git_quiet "$UP" init -q --initial-branch=dev || git -C "$UP" init -q
printf 'v1\n' > "$UP/.claude/hooks/sample-gate.sh"
git_quiet "$UP" add .claude/hooks/sample-gate.sh
git_quiet "$UP" -c user.email=t@t -c user.name=t commit -m "add gate"

FORK="$TMP/fork"
git clone -q "$UP" "$FORK" 2>/dev/null
git_quiet "$FORK" remote add upstream "$UP"
git_quiet "$FORK" fetch upstream

# --- 1. Fork is current: silent. ---
assert_silent "current fork is silent" "$(hook_drift_notice "$FORK/.claude/hooks/sample-gate.sh")"

# --- 2. Adopter customised the hook locally: still silent. ---
# The helper asks "does upstream have commits I lack", not "do we differ", so
# a local edit alone must not trigger it.
printf 'v1-local-tweak\n' > "$FORK/.claude/hooks/sample-gate.sh"
git_quiet "$FORK" add .claude/hooks/sample-gate.sh
git_quiet "$FORK" -c user.email=t@t -c user.name=t commit -m "local customisation"
assert_silent "local customisation is silent" "$(hook_drift_notice "$FORK/.claude/hooks/sample-gate.sh")"

# --- 3. Upstream moves ahead on that file: notice fires. ---
printf 'v2\n' > "$UP/.claude/hooks/sample-gate.sh"
git_quiet "$UP" add .claude/hooks/sample-gate.sh
git_quiet "$UP" -c user.email=t@t -c user.name=t commit -m "fix the gate"
git_quiet "$FORK" fetch upstream
out=$(hook_drift_notice "$FORK/.claude/hooks/sample-gate.sh")
assert_mentions "upstream-ahead fires"        "$out" "upstream has 1 commit "
assert_mentions "names the file"              "$out" ".claude/hooks/sample-gate.sh"
assert_mentions "points at /update"           "$out" "/update"

# --- 4. Upstream moves ahead on a DIFFERENT file: silent for ours. ---
printf 'x\n' > "$UP/.claude/hooks/other-gate.sh"
git_quiet "$UP" add .claude/hooks/other-gate.sh
git_quiet "$UP" -c user.email=t@t -c user.name=t commit -m "unrelated"
git_quiet "$FORK" fetch upstream
before=$(hook_drift_notice "$FORK/.claude/hooks/sample-gate.sh")
assert_mentions "unrelated commit does not inflate the count" "$before" "upstream has 1 commit "

# --- 5. No upstream remote: silent. ---
SOLO="$TMP/solo"
mkdir -p "$SOLO/.claude/hooks"
git_quiet "$SOLO" init -q
printf 'v1\n' > "$SOLO/.claude/hooks/sample-gate.sh"
git_quiet "$SOLO" add .claude/hooks/sample-gate.sh
git_quiet "$SOLO" -c user.email=t@t -c user.name=t commit -m "init"
assert_silent "no upstream remote is silent" "$(hook_drift_notice "$SOLO/.claude/hooks/sample-gate.sh")"

# --- 6. Not a git repo at all: silent. ---
mkdir -p "$TMP/plain/.claude/hooks"
printf 'v1\n' > "$TMP/plain/.claude/hooks/sample-gate.sh"
assert_silent "non-repo is silent" "$(hook_drift_notice "$TMP/plain/.claude/hooks/sample-gate.sh" 2>/dev/null)"

# --- 7. Empty / missing argument: silent, no error. ---
assert_silent "empty argument is silent" "$(hook_drift_notice "" 2>/dev/null)"
assert_silent "missing file is silent"   "$(hook_drift_notice "$FORK/.claude/hooks/nope.sh" 2>/dev/null)"

echo
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
[ "$FAIL" -eq 0 ]
