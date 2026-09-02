#!/usr/bin/env bash
# Read channels.txt -- the only place a Mesa version is pinned.
#
#   ./resolve-channel.sh --list        JSON array of every channel, for the build matrix
#   ./resolve-channel.sh <channel>     `key=value` lines for $GITHUB_OUTPUT:
#                                      channel, ppa, version,
#                                      base_image, tdarr_version, base_held, list
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
[ "$(echo "$rows" | awk 'NF<3 || NF>4' | wc -l | tr -d ' ')" -eq 0 ] \
  || die "every row needs 3 or 4 fields (channel ppa version [hold])"

# Field 4 is the freeze marker read by refresh-channels.py, and 'hold' is its only legal value.
# Checked here, in the script every build runs, so a typo'd marker cannot quietly read as
# "not frozen" and let the next refresh overwrite a deliberate pin.
[ "$(echo "$rows" | awk 'NF==4 && $4!="hold"' | wc -l | tr -d ' ')" -eq 0 ] \
  || die "field 4, when present, must be exactly 'hold'"

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

# The exact tag names the base as well as the Mesa, so the tag list needs the upstream
# version. Read it through resolve-base.sh rather than parsing base.txt again here: one
# parser means one set of rules, and the reference the build uses cannot drift from the
# version the tag claims.
base_out="$("$here/resolve-base.sh")" || die "resolve-base.sh failed"
base_image="$(echo "$base_out" | sed -n 's/^base_image=//p')"
tdarr_version="$(echo "$base_out" | sed -n 's/^tdarr_version=//p')"
base_held="$(echo "$base_out" | sed -n 's/^base_held=//p')"
[ -n "$base_image" ] && [ -n "$tdarr_version" ] \
  || die "resolve-base.sh emitted no base_image/tdarr_version"

# No :latest and no floating cross-channel tag: every tag names the channel or the build.
# Three tags, as before -- the middle one now identifies both moving inputs, so an exact tag
# pins the driver AND the Tdarr it was built on.
#
# Deliberately absent, so a later round does not re-add them:
#   :<channel>-tdarr-<version>  -- pinning upstream while floating Mesa serves nobody. You
#                                  want newest-of-both (:<channel>) or one exact build.
#   :<channel>-tdarr-latest     -- :<channel> already means that. The two would differ only
#                                  while base.txt is held, which is not worth a tag that is
#                                  a duplicate the rest of the time.
list="${image}:${channel},${image}:${channel}-${safe_version}-tdarr-${tdarr_version},${image}:${GITHUB_SHA:-local}"

for t in $(echo "$list" | tr ',' ' '); do
  tag="${t##*:}"
  echo "$tag" | grep -qE '^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$' || die "illegal docker tag: '$tag'"
done

echo "channel=${channel}"
echo "ppa=${ppa}"
echo "version=${version}"
echo "base_image=${base_image}"
echo "tdarr_version=${tdarr_version}"
echo "base_held=${base_held}"
echo "list=${list}"
