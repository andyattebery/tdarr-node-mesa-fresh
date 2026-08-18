#!/usr/bin/env bash
# Resolve a Mesa channel from channels.txt into build args and an image tag list.
#
#   ./resolve-channel.sh [channel]
#
# An empty channel resolves to whichever row is marked `stable` -- that is the push-event
# case, where workflow_dispatch inputs do not exist.
#
# Emits `key=value` lines for $GITHUB_OUTPUT: channel, ppa, version, list.
# Exits non-zero, with a reason on stderr, rather than emitting anything questionable.
set -euo pipefail

want="${1-}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
file="${CHANNELS_FILE:-$here/channels.txt}"
image="${IMAGE:-ghcr.io/andyattebery/tdarr-node-mesa-fresh}"

die() { echo "resolve-channel: $*" >&2; exit 1; }

[ -r "$file" ] || die "cannot read $file"

# Strip comments and blank lines once; every pass below reads this.
rows="$(sed 's/#.*//' "$file" | awk 'NF')"
[ -n "$rows" ] && [ "$(echo "$rows" | awk 'NF!=4' | wc -l)" -eq 0 ] \
  || die "every row needs exactly 4 fields (channel ppa version stability)"

# Exactly one stable row. Zero means :latest silently stops being published; two means two
# channels race for it. Neither announces itself, so it is asserted rather than assumed.
stable_rows="$(echo "$rows" | awk '$4=="stable"')"
n_stable="$(echo "$stable_rows" | awk 'NF' | wc -l | tr -d ' ')"
[ "$n_stable" = 1 ] || die "expected exactly 1 stable channel in $file, found $n_stable"
stable_channel="$(echo "$stable_rows" | awk '{print $1}')"

[ -n "$want" ] || want="$stable_channel"

row="$(echo "$rows" | awk -v c="$want" '$1==c')"
[ -n "$row" ] || die "no row for channel '$want' in $file (have: $(echo "$rows" | awk '{print $1}' | tr '\n' ' '))"
[ "$(echo "$row" | wc -l | tr -d ' ')" = 1 ] || die "channel '$want' appears more than once in $file"

channel="$(echo "$row" | awk '{print $1}')"
ppa="$(echo "$row" | awk '{print $2}')"
version="$(echo "$row" | awk '{print $3}')"
stability="$(echo "$row" | awk '{print $4}')"

case "$stability" in
  stable|preview) ;;
  *) die "stability for '$channel' must be stable or preview, got '$stability'" ;;
esac

# The version must carry the channel's own marker. This no longer guards user input -- a
# mismatched pair is not expressible any more -- it guards THIS FILE: a mesarc version
# pasted into the kisak row would otherwise ship an image tagged :kisak carrying 26.2.
case "$version" in
  *"$channel"*) ;;
  *) die "version '$version' does not contain '$channel'; wrong row?" ;;
esac

# Docker tags allow only [A-Za-z0-9_][A-Za-z0-9._-]*, and Mesa package versions use both
# '~' and '+'.
safe_version="$(printf '%s' "$version" | tr '~+' '--')"

list="${image}:${channel},${image}:${channel}-${safe_version},${image}:${GITHUB_SHA:-local}"
# :latest follows the stable row only, so a one-off preview build cannot repoint it and
# quietly hand a development-release driver to anything deploying from that tag.
[ "$stability" = stable ] && list="${list},${image}:latest"

for t in $(echo "$list" | tr ',' ' '); do
  tag="${t##*:}"
  echo "$tag" | grep -qE '^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$' || die "illegal docker tag: '$tag'"
done

echo "channel=${channel}"
echo "ppa=${ppa}"
echo "version=${version}"
echo "list=${list}"
