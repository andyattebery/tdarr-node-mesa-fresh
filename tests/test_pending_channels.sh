#!/usr/bin/env bash
# pending-channels.sh -- 15 cases: 8 reachable die sites plus 7 behavioural.
#
# Every registry call goes through tests/fixtures/bin/curl, prepended to PATH. If that stub is
# ever bypassed these tests silently start talking to the real GHCR and become worthless, so
# run.sh proves the stub is in use before this file runs.
#
# L87 and L99 are deliberately absent: both are unreachable, because `set -e` on the preceding
# command substitution kills the script first. See plans/add-tests.md.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
CURRENT_SUITE=pending-channels

P="${REPO}/pending-channels.sh"
export PATH="${FIXTURES}/bin:${PATH}"

# IMAGE must stay on ghcr.io -- the script refuses anything else by design -- so the stub
# intercepts by PATH, not by hostname.
run() { CURL_STUB="$1" \
        CHANNELS_FILE="${FIXTURES}/channels-good.txt" \
        BASE_FILE="${FIXTURES}/base-good.txt" \
        IMAGE=ghcr.io/test/img "$P"; }

# --- the 8 reachable die sites ---
assert_dies "L41 IMAGE not on ghcr.io" -- \
  env CURL_STUB=all-absent CHANNELS_FILE="${FIXTURES}/channels-good.txt" \
      BASE_FILE="${FIXTURES}/base-good.txt" IMAGE=docker.io/test/img "$P"
assert_dies "L56/L59 curl fails on the token request" -- run token-transport-fail
assert_dies "L62 token reply carries no token"        -- run token-no-token
assert_dies "L71 curl fails on the manifest HEAD"     -- run manifest-transport-fail
# The two regression tests for the status-masking bugs. assert_dies checks empty stdout, which
# is the half that matters: with the bug present the script survived and printed an array.
assert_dies "L78 200 without Docker-Content-Digest"   -- run manifest-200-no-digest
assert_dies "L80 unexpected HTTP 500"                 -- run manifest-500
assert_dies "L85 resolve-channel.sh --list fails" -- \
  env CURL_STUB=all-absent CHANNELS_FILE="${FIXTURES}/channels-empty.txt" \
      BASE_FILE="${FIXTURES}/base-good.txt" IMAGE=ghcr.io/test/img "$P"

# --- behavioural ---
assert_ok "nothing published"   -- env CURL_STUB=all-absent CHANNELS_FILE="${FIXTURES}/channels-good.txt" BASE_FILE="${FIXTURES}/base-good.txt" IMAGE=ghcr.io/test/img "$P"
assert_eq '["kisak","mesarc"]' "$STDOUT" "all absent -> every channel pending"

assert_ok "all published, moving agrees" -- env CURL_STUB=all-present CHANNELS_FILE="${FIXTURES}/channels-good.txt" BASE_FILE="${FIXTURES}/base-good.txt" IMAGE=ghcr.io/test/img "$P"
assert_eq '[]' "$STDOUT" "everything current -> nothing pending"

assert_ok "moving tag drifted" -- env CURL_STUB=moving-drifted CHANNELS_FILE="${FIXTURES}/channels-good.txt" BASE_FILE="${FIXTURES}/base-good.txt" IMAGE=ghcr.io/test/img "$P"
assert_eq '["kisak","mesarc"]' "$STDOUT" \
  "exact tag present but :<channel> points elsewhere -> pending (the rollback-under-hold case)"

assert_ok "moving tag absent" -- env CURL_STUB=moving-absent CHANNELS_FILE="${FIXTURES}/channels-good.txt" BASE_FILE="${FIXTURES}/base-good.txt" IMAGE=ghcr.io/test/img "$P"
assert_eq '["kisak","mesarc"]' "$STDOUT" "exact tag present but :<channel> missing -> pending"

assert_ok "one pending, one not" -- env CURL_STUB=mixed CHANNELS_FILE="${FIXTURES}/channels-good.txt" BASE_FILE="${FIXTURES}/base-good.txt" IMAGE=ghcr.io/test/img "$P"
assert_eq '["kisak"]' "$STDOUT" "the array is filtered, not all-or-nothing"

summary
exit "$FAIL"
