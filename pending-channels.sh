#!/usr/bin/env bash
# Which channels are NOT published in the state the pins describe.
#
#   ./pending-channels.sh     JSON array of channels needing a build, for the build matrix
#
# This asks the registry rather than tracking what changed during a run, and that difference is
# the whole point. "What moved since I last looked" is a fact that exists only in the memory of
# one workflow run: if that run commits a pin and then dies before publishing -- as run
# 33961302606 did on 2026-09-05, when add-apt-repository got a 504 out of Launchpad -- the next
# run compares the PPA against channels.txt, finds them equal, reports "up to date" and builds
# nothing. The repo then claims a version it has never shipped, for ever, until a human notices.
#
# "Is the image the pins describe actually published" is instead re-derivable from scratch at
# any time, which makes the daily run idempotent: a failed build is simply retried the next day,
# with no state carried between runs and no retry bookkeeping to get wrong.
#
# It also subsumes every trigger the old logic special-cased:
#
#   Mesa moved              -> exact tag is new -> absent   -> build
#   base moved              -> exact tag is new -> absent   -> build (every channel, for free)
#   previous build failed   -> exact tag still absent       -> build, healing itself
#   nothing moved           -> exact tag present, :<channel> agrees -> skip
#   rolled back under hold  -> exact tag present, :<channel> stale  -> build, fixing the pointer
#
# That last row is why the moving tag is checked too and not just the exact one. Rolling a
# channel back to an already-built version leaves its exact tag present while :<channel> still
# points at the newer image, so an exact-tag-only check would call it done and leave the moving
# tag lying about which driver it carries.
#
# Exits non-zero with a reason on stderr rather than emitting a partial array.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
image="${IMAGE:-ghcr.io/andyattebery/tdarr-node-mesa-fresh}"

die() { echo "pending-channels: $*" >&2; exit 1; }

# The registry host is not part of the repository path in a /v2/ URL.
registry="${image%%/*}"
repo="${image#*/}"
[ "$registry" = ghcr.io ] || die "$image is not on ghcr.io; this script only speaks to ghcr.io"

# All four, as refresh-base.py does: without them GHCR may answer with a schema that carries no
# Docker-Content-Digest, and the moving-tag comparison below would silently compare two blanks.
accept='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'

# --retry covers the transport flakiness that motivated this script in the first place. Note
# --retry-all-errors: without it curl retries only a subset, and a bare 500 would not be retried.
curl_opts=(--silent --show-error --retry 5 --retry-delay 2 --retry-all-errors)

# A pull token. GITHUB_TOKEN when the workflow has one, anonymous otherwise -- the package is
# public, so the anonymous path is the one a local run takes and is genuinely exercised.
token_url="https://${registry}/token?scope=repository:${repo}:pull&service=${registry}"
if [ -n "${GITHUB_TOKEN:-}" ]; then
  token_json="$(curl "${curl_opts[@]}" -u "x:${GITHUB_TOKEN}" "$token_url")" \
    || die "could not fetch a pull token for ${repo}"
else
  token_json="$(curl "${curl_opts[@]}" "$token_url")" \
    || die "could not fetch a pull token for ${repo}"
fi
token="$(printf '%s' "$token_json" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')"
[ -n "$token" ] || die "no token in the registry's reply for ${repo}"

# Echoes "<http status> <digest>". A tag that does not exist is a legitimate answer (404) and
# means "needs building"; anything else is not an answer at all and must not be guessed at.
manifest() {
  local ref="$1" out status digest
  out="$(curl "${curl_opts[@]}" --head --write-out '\n%{http_code}' \
        -H "Authorization: Bearer ${token}" -H "Accept: ${accept}" \
        "https://${registry}/v2/${repo}/manifests/${ref}")" \
    || die "HEAD ${ref} failed"
  status="$(printf '%s' "$out" | tail -n1)"
  digest="$(printf '%s' "$out" | tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}')"
  # 200 and 404 are the only two answers this script knows how to act on. Treating a 5xx as
  # "absent" would merely waste a build; treating it as "present" would silently skip one, which
  # is exactly the failure mode this script exists to remove. So neither: fail the run.
  case "$status" in
    200) [ -n "$digest" ] || die "200 for ${ref} but no Docker-Content-Digest header" ;;
    404) ;;
    *)   die "unexpected HTTP ${status} for ${ref}; refusing to guess whether it exists" ;;
  esac
  printf '%s %s' "$status" "$digest"
}

channels="$("$here/resolve-channel.sh" --list)" || die "resolve-channel.sh --list failed"
names="$(printf '%s' "$channels" | tr -d '[]"' | tr ',' ' ')"
[ -n "$names" ] || die "resolve-channel.sh --list returned no channels"

pending=()
for ch in $names; do
  # resolve-channel.sh is the single source for the tag, as everywhere else. Assigned before
  # being eval'd for the same reason as the manifest calls below: `eval "$(cmd)"` reports eval's
  # status, not cmd's, so a failure would go unnoticed -- and worse than unnoticed, because
  # exact_tag would still hold the PREVIOUS channel's value and this iteration would reconcile
  # one channel against another channel's tag.
  unset exact_tag
  channel_vars="$("$here/resolve-channel.sh" "$ch")"
  eval "$channel_vars"
  [ -n "${exact_tag:-}" ] || die "resolve-channel.sh $ch emitted no exact_tag"

  # Assign, THEN split. `read ... <<<"$(manifest ...)"` looks equivalent and is not: a die()
  # inside the command substitution is swallowed, because read's own exit status replaces it.
  # The script would carry on with an empty status, match neither branch, compare two empty
  # digests as equal, and report the channel up to date -- a registry error silently skipping a
  # build, which is the one outcome this whole file exists to prevent. A plain assignment
  # propagates the failure under set -e.
  exact_out="$(manifest "$exact_tag")"
  exact_status="${exact_out%% *}"
  exact_digest="${exact_out#* }"
  if [ "$exact_status" = 404 ]; then
    echo "  ${ch}: ${exact_tag} not published -- BUILD" >&2
    pending+=("$ch")
    continue
  fi

  moving_out="$(manifest "$ch")"
  moving_digest="${moving_out#* }"
  if [ "$moving_digest" != "$exact_digest" ]; then
    echo "  ${ch}: :${ch} points at ${moving_digest:-nothing}, not ${exact_tag} -- BUILD" >&2
    pending+=("$ch")
    continue
  fi

  echo "  ${ch}: ${exact_tag} published, :${ch} agrees -- up to date" >&2
done

# Emitted last and in one go: a partial array reaching the matrix would build a wrong subset,
# which is worse than building nothing.
printf '['
for i in "${!pending[@]}"; do
  [ "$i" -gt 0 ] && printf ','
  printf '"%s"' "${pending[$i]}"
done
printf ']\n'
