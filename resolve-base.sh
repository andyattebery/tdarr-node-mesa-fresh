#!/usr/bin/env bash
# Read base.txt -- the only place the upstream base image is pinned.
#
#   ./resolve-base.sh     `key=value` lines for $GITHUB_OUTPUT:
#                         base_image, tdarr_version
#
# base_image is assembled here, and only here, so the reference the build uses and the
# version the tags carry come from one row read once. Same argument as resolve-channel.sh
# building the tag list: two readers of one file can disagree; one reader cannot.
#
# Exits non-zero with a reason on stderr rather than emitting anything questionable.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
file="${BASE_FILE:-$here/base.txt}"

die() { echo "resolve-base: $*" >&2; exit 1; }

[ -r "$file" ] || die "cannot read $file"

rows="$(sed 's/#.*//' "$file" | awk 'NF')"
[ -n "$rows" ] || die "$file lists no base image"

# Exactly one, not "the first one". A second row is a mistake with a silent failure mode:
# whichever came first would win and the other would be ignored.
n="$(echo "$rows" | wc -l | tr -d ' ')"
[ "$n" -eq 1 ] || die "$file must hold exactly one row, found $n"

set -- $rows
case $# in
  3|4) ;;
  *) die "the row needs 3 or 4 fields (image version digest [hold]), got $#" ;;
esac

image="$1"
version="$2"
digest="$3"
held=false

# Field 4 is the freeze marker read by refresh-base.py, and 'hold' is its only legal value.
# Checked here, in the script every build runs, so a typo'd marker cannot quietly read as
# "not frozen" and let the next refresh overwrite a deliberate pin.
if [ $# -eq 4 ]; then
  [ "$4" = hold ] || die "field 4 is '$4'; the only allowed value is 'hold'"
  held=true
fi

# A truncated or malformed digest would still make a syntactically valid reference, and the
# failure would surface as an opaque registry error at build time.
echo "$digest" | grep -qE '^sha256:[0-9a-f]{64}$' \
  || die "digest '$digest' is not a sha256:<64 hex> reference"

# The version lands in a docker tag as well as in the image reference, so it has to survive
# both. Checked here rather than downstream: this is where it is read.
echo "$version" | grep -qE '^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$' \
  || die "version '$version' is not usable as a docker tag"

echo "$image" | grep -qE '^[a-z0-9.-]+(:[0-9]+)?/[a-z0-9._/-]+$' \
  || die "image '$image' does not look like a registry/repository reference"

# Digest AND tag. Buildkit resolves the digest; the tag is there to be read by humans in
# build logs, `docker history`, and the base.name label.
echo "base_image=${image}:${version}@${digest}"
echo "tdarr_version=${version}"
echo "base_held=${held}"
