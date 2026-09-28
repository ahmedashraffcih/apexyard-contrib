#!/bin/bash
# Stale-hook notice (me2resh/apexyard#1449).
#
# A fork trails `dev` between tagged releases — that is what the release-cut
# model produces, and `check-upstream-drift.sh` stays deliberately quiet about
# it so its own banner keeps meaning "a release is out". The cost is that a
# fork owner reading a hook has no way to know whether it is the current one.
# When a gate then refuses something that looks like it should have passed,
# the natural next step is to investigate the hook, or file a bug against it,
# against a copy upstream may have already fixed.
#
# `hook_drift_notice <hook-file>` prints one short paragraph when upstream has
# commits touching that file which this fork does not have, and prints nothing
# otherwise. Callers append it to a refusal message they were printing anyway.
#
# Two properties this deliberately has:
#
#   - It NEVER performs network I/O. It compares against an `upstream/*` ref
#     that is already in the local object store. A hook runs inside a
#     PreToolUse call, where a fetch could hang on a credential prompt or a
#     dead network; a silent, possibly-stale answer is the right trade.
#   - It asks "does upstream have commits for this file that I lack?"
#     (`git log HEAD..<ref> -- <path>`), NOT "does my copy differ from
#     upstream?". An adopter who has deliberately customised a hook differs
#     from upstream forever; they are not behind it, and telling them to run
#     /update every time their own hook fires would be noise of exactly the
#     kind #1449 exists to avoid.
#
# Advisory only. Every failure path returns 0 and prints nothing: a gate must
# refuse or permit on its own logic, never on whether this helper worked.

hook_drift_notice() {
  local hook_file="$1"
  [ -n "$hook_file" ] || return 0
  command -v git >/dev/null 2>&1 || return 0

  local dir abs root rel ref cand count
  # `pwd -P` and `--show-toplevel` must both be physical paths, or the prefix
  # strip below silently fails and the notice never fires. On macOS a temp or
  # home path is routinely a symlink (/var -> /private/var), so a logical
  # `pwd` here would disagree with git's answer for the same directory.
  dir=$(CDPATH='' cd -- "$(dirname -- "$hook_file")" 2>/dev/null && pwd -P) || return 0
  abs="$dir/$(basename -- "$hook_file")"
  root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || return 0
  [ -n "$root" ] || return 0
  root=$(CDPATH='' cd -- "$root" 2>/dev/null && pwd -P) || return 0

  # No upstream remote means no fork relationship to report on.
  git -C "$root" remote get-url upstream >/dev/null 2>&1 || return 0

  # First upstream ref that exists LOCALLY. A fork that has never fetched
  # upstream gets silence rather than a fetch. The candidates are listed
  # literally rather than expanded from a variable: an unquoted expansion
  # would depend on the shell word-splitting it, which bash does and zsh does
  # not, so a future caller sourcing this from a non-bash shell would silently
  # get one nonsense ref name instead of three real ones.
  # Order follows the release-cut model: `dev` carries daily merges, `main`
  # only tagged releases.
  ref=""
  for cand in upstream/dev upstream/main upstream/master; do
    if git -C "$root" rev-parse --verify --quiet "$cand" >/dev/null 2>&1; then
      ref="$cand"
      break
    fi
  done
  [ -n "$ref" ] || return 0

  rel="${abs#"$root"/}"
  # An absolute path that never had $root as a prefix is not a file in this
  # repository; path-filtering on it would silently match nothing.
  case "$rel" in /*) return 0 ;; esac

  count=$(git -C "$root" rev-list --count "HEAD..$ref" -- "$rel" 2>/dev/null) || return 0
  [ -n "$count" ] && [ "$count" -gt 0 ] 2>/dev/null || return 0

  local plural="s"
  [ "$count" = "1" ] && plural=""

  cat <<MSG

Note: this refusal came from your fork's copy of
  $rel
and upstream has $count commit$plural touching that file which your fork does not
have. It may already be fixed. Run /update before investigating the hook or
filing a bug against it.
MSG
}
