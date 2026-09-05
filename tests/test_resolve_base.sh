#!/usr/bin/env bash
# resolve-base.sh -- 10 cases: all 8 die sites, plus the two success shapes.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
CURRENT_SUITE=resolve-base

R="${REPO}/resolve-base.sh"
run() { BASE_FILE="${FIXTURES}/$1" "$R"; }

# --- the 8 die sites ---
assert_dies "L19 unreadable file"        -- env BASE_FILE="${FIXTURES}/nope.txt" "$R"
assert_dies "L22 no data rows"           -- run base-empty.txt
assert_dies "L27 two rows"               -- run base-two-rows.txt
assert_dies "L32 wrong field count"      -- run base-two-fields.txt
assert_dies "L44 field 4 not 'hold'"     -- run base-bad-hold.txt
assert_dies "L51 truncated digest"       -- run base-short-digest.txt
assert_dies "L56 version not tag-safe"   -- run base-bad-version.txt
assert_dies "L59 image not registry/repo" -- run base-bad-image.txt

# --- the valid case ---
assert_ok "valid row resolves" -- env BASE_FILE="${FIXTURES}/base-good.txt" "$R"
assert_eq \
  "ghcr.io/haveagitgat/tdarr_node:2.86.01@sha256:7542459ac5ed5cd299600530e9625b9d590629d5dc391c0016773f5d6aa3fe75" \
  "$(printf '%s\n' "$STDOUT" | field base_image)" \
  "base_image is image:version@digest"
assert_eq "2.86.01" "$(printf '%s\n' "$STDOUT" | field tdarr_version)" "tdarr_version"
assert_eq "false"   "$(printf '%s\n' "$STDOUT" | field base_held)"    "base_held false when not held"

# --- the held case ---
assert_ok "held row resolves" -- env BASE_FILE="${FIXTURES}/base-held.txt" "$R"
assert_eq "true" "$(printf '%s\n' "$STDOUT" | field base_held)" "base_held true when held"

summary
exit "$FAIL"
