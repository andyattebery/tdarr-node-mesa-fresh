#!/usr/bin/env bash
# Assertions for the shell suites. Sourced, never run directly.
#
# Deliberately tiny and dependency-free: the scripts under test are stdlib-only bash and the
# tests should need nothing installed either.
#
# NOTE: the shell you type commands into may not be bash (it is zsh on the machine this was
# written on), so every test file carries its own bash shebang and is invoked as ./tests/x.sh.
# Nothing here may assume the caller is bash.

PASS=0
FAIL=0
FAILURES=()

# Where the scripts under test live.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="${REPO}/tests/fixtures"

ok() { PASS=$((PASS + 1)); }

fail() {
  FAIL=$((FAIL + 1))
  FAILURES+=("${CURRENT_SUITE:-?}: $1")
  echo "  FAIL  $1" >&2
  [ -n "${2:-}" ] && echo "        expected: $2" >&2
  [ -n "${3:-}" ] && echo "        actual:   $3" >&2
  return 0
}

assert_eq() { # want got name
  if [ "$1" = "$2" ]; then ok; else fail "$3" "$1" "$2"; fi
}

assert_contains() { # haystack needle name
  case "$1" in
    *"$2"*) ok ;;
    *) fail "$3" "output containing '$2'" "$1" ;;
  esac
}

# The workhorse. A script that dies must do all three of these, and the stdout check is the
# one that matters most: every script here feeds a build matrix or a build arg, so dying
# *after* printing a partial value is strictly worse than printing nothing. The two
# status-masking bugs this suite exists to catch both showed up as "exited fine, printed a
# wrong answer", which an exit-code-only assertion would have missed.
assert_dies() { # name -- cmd...
  local name="$1"; shift
  [ "$1" = -- ] && shift
  local out err rc
  err="$(mktemp)"
  out="$("$@" 2>"$err")" && rc=0 || rc=$?
  local stderr; stderr="$(cat "$err")"; rm -f "$err"

  if [ "$rc" -eq 0 ]; then
    fail "$name (expected non-zero exit)" "non-zero" "0"
  elif [ -n "$out" ]; then
    fail "$name (died but printed to stdout)" "empty stdout" "$out"
  elif [ -z "$stderr" ]; then
    fail "$name (died silently)" "a reason on stderr" "<nothing>"
  else
    ok
  fi
}

# Runs cmd, asserts success, and hands stdout back in $STDOUT.
assert_ok() { # name -- cmd...
  local name="$1"; shift
  [ "$1" = -- ] && shift
  if STDOUT="$("$@" 2>/dev/null)"; then ok; else fail "$name (expected success)" "exit 0" "exit $?"; fi
}

# Pulls one `key=value` line out of a resolver's output.
field() { # key <<< output
  sed -n "s/^$1=//p"
}

summary() {
  if [ "$FAIL" -eq 0 ]; then
    echo "  ${PASS} passed"
  else
    echo "  ${PASS} passed, ${FAIL} FAILED" >&2
  fi
  return 0
}
