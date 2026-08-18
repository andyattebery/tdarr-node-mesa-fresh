#!/usr/bin/env bash
# Read channels.txt -- the only place a Mesa version is pinned.
#
#   ./resolve-channel.sh --list        JSON array of every channel, for the build matrix
#   ./resolve-channel.sh <channel>     `key=value` lines for $GITHUB_OUTPUT:
#                                      channel, ppa, version, list
#
# Exits non-zero with a reason on stderr rather than emitting anything questionable.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
file="${CHANNELS_FILE:-$here/channels.txt}"
image="${IMAGE:-ghcr.io/andyattebery/tdarr-node-mesa-fresh}"

die() { echo "resolve-channel: $*" >&2; exit 1; }

[ -r "$file" ] || die "cannot read $file"

# Strip comments and blank lines once; every pass below reads this.
rows="$(sed 's/#.*//' "$file" | awk 'NF')"
[ -n "$rows" ] || die "$file lists no channels"
[ "$(echo "$rows" | awk 'NF!=3' | wc -l | tr -d ' ')" -eq 0 ] \
  || die "every row needs exactly 3 fields (channel ppa version)"

names="$(echo "$rows" | awk '{print $1}')"
[ "$(echo "$names" | sort -u | wc -l | tr -d ' ')" = "$(echo "$names" | wc -l | tr -d ' ')" ] \
  || die "duplicate channel name in $file"

# --list feeds `strategy.matrix`, which needs JSON. Emitted here rather than built with
# string surgery in YAML, so the matrix and a single build read the same file the same way.
if [ "${1-}" = --list ]; then
  printf '['
  printf '%s' "$names" | awk 'NR>1{printf ","} {printf "\"%s\"", $1}'
  printf ']\n'
  exit 0
fi

want="${1-}"
[ -n "$want" ] || die "usage: resolve-channel.sh --list | <channel>"

row="$(echo "$rows" | awk -v c="$want" '$1==c')"
[ -n "$row" ] || die "no row for channel '$want' in $file (have: $(echo "$names" | tr '\n' ' '))"

channel="$(echo "$row" | awk '{print $1}')"
ppa="$(echo "$row" | awk '{print $2}')"
version="$(echo "$row" | awk '{print $3}')"

# The version must carry the channel's own name. This does not guard user input -- the
# channel is a closed choice -- it guards THIS FILE: a mesarc version pasted into the kisak
# row would otherwise ship an image tagged :kisak carrying 26.2.
case "$version" in
  *"$channel"*) ;;
  *) die "version '$version' does not contain '$channel'; wrong row?" ;;
esac

# Docker tags allow only [A-Za-z0-9_][A-Za-z0-9._-]*, and Mesa package versions use both
# '~' and '+'.
safe_version="$(printf '%s' "$version" | tr '~+' '--')"

# No :latest and no floating cross-channel tag: every tag names the channel or the build.
list="${image}:${channel},${image}:${channel}-${safe_version},${image}:${GITHUB_SHA:-local}"

for t in $(echo "$list" | tr ',' ' '); do
  tag="${t##*:}"
  echo "$tag" | grep -qE '^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$' || die "illegal docker tag: '$tag'"
done

echo "channel=${channel}"
echo "ppa=${ppa}"
echo "version=${version}"
echo "list=${list}"
