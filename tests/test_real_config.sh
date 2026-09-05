#!/usr/bin/env bash
# The ONLY suite that reads the committed channels.txt and base.txt.
#
# Everything else runs against fixtures, deliberately. This one exists so a bad hand-edit to
# the real config is caught here rather than by the nightly run. It makes no network calls --
# the resolvers are pure file parsing.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
CURRENT_SUITE=real-config

assert_ok "committed base.txt resolves"     -- "${REPO}/resolve-base.sh"
assert_ok "committed channels.txt --list"   -- "${REPO}/resolve-channel.sh" --list

# "every channel resolves" is a claim about the set channels.txt actually names, so ask it
# rather than hardcoding two.
for ch in $(printf '%s' "$STDOUT" | tr -d '[]"' | tr ',' ' '); do
  assert_ok "committed channel '$ch' resolves" -- "${REPO}/resolve-channel.sh" "$ch"
done

summary
exit "$FAIL"
