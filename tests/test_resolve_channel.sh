#!/usr/bin/env bash
# resolve-channel.sh -- 14 cases: 10 reachable die sites plus 4 behavioural.
#
# L76 ("resolve-base.sh emitted no base_image/tdarr_version") is deliberately absent: it is
# unreachable, because resolve-base.sh either dies or emits both, and `set -e` on the
# assignment kills this script first. See plans/add-tests.md.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
CURRENT_SUITE=resolve-channel

R="${REPO}/resolve-channel.sh"
# Every case pins BASE_FILE at a fixture so the suite never depends on the committed base.txt.
run() { local ch="$1"; shift; CHANNELS_FILE="${FIXTURES}/${1:-channels-good.txt}" \
        BASE_FILE="${FIXTURES}/base-good.txt" "$R" "$ch"; }

# --- the 10 reachable die sites ---
assert_dies "L18 unreadable file" -- \
  env CHANNELS_FILE="${FIXTURES}/nope.txt" BASE_FILE="${FIXTURES}/base-good.txt" "$R" kisak
assert_dies "L22 no channels"          -- run kisak channels-empty.txt
assert_dies "L24 too few fields"       -- run kisak channels-two-fields.txt
assert_dies "L24 too many fields"      -- run kisak channels-five-fields.txt
assert_dies "L30 field 4 not 'hold'"   -- run kisak channels-bad-hold.txt
assert_dies "L34 duplicate channel"    -- run kisak channels-dup.txt
assert_dies "L46 no argument at all"   -- \
  env CHANNELS_FILE="${FIXTURES}/channels-good.txt" BASE_FILE="${FIXTURES}/base-good.txt" "$R"
assert_dies "L49 unknown channel"      -- run nosuchchannel
assert_dies "L60 version lacks channel name" -- run kisak channels-wrong-version.txt
assert_dies "L100 illegal docker tag"  -- run -x channels-illegal-tag.txt
assert_dies "L71 resolve-base failure propagates" -- \
  env CHANNELS_FILE="${FIXTURES}/channels-good.txt" BASE_FILE="${FIXTURES}/base-short-digest.txt" "$R" kisak

# --- behavioural ---
assert_ok "--list succeeds" -- \
  env CHANNELS_FILE="${FIXTURES}/channels-good.txt" BASE_FILE="${FIXTURES}/base-good.txt" "$R" --list
assert_eq '["kisak","mesarc"]' "$STDOUT" "--list emits a JSON array"

assert_ok "kisak resolves" -- \
  env CHANNELS_FILE="${FIXTURES}/channels-good.txt" BASE_FILE="${FIXTURES}/base-good.txt" \
      IMAGE=example.test/img "$R" kisak
out="$STDOUT"
assert_eq "kisak-26.2.2-kisak1-n-tdarr-2.86.01" "$(printf '%s\n' "$out" | field exact_tag)" \
  "exact_tag is <channel>-<safe>-tdarr-<tdarr>, with ~ and + folded to -"
# The invariant that stops the reconciler hunting a tag the build never pushes.
assert_contains "$(printf '%s\n' "$out" | field list)" \
  ":$(printf '%s\n' "$out" | field exact_tag)," \
  "exact_tag appears verbatim inside list="

assert_ok "mesarc resolves (the + case)" -- \
  env CHANNELS_FILE="${FIXTURES}/channels-good.txt" BASE_FILE="${FIXTURES}/base-good.txt" "$R" mesarc
assert_eq "mesarc-26.2.1-git99-n-mesarc0-tdarr-2.86.01" \
  "$(printf '%s\n' "$STDOUT" | field exact_tag)" "'+' folded to '-' as well as '~'"

summary
exit "$FAIL"
