#!/usr/bin/env bash
# The whole suite. No network, no Docker, no dependencies beyond bash and python3.
#
#   ./tests/run.sh
#
# What this does NOT cover, so a green run is not mistaken for more than it is:
#   * the Containerfile -- its add-apt-repository retry loop, its three `test -n` guards, the
#     BASE_IMAGE-empty failure at FROM, and the mesa-libgallium / radeonsi_drv_video.so gates.
#     Testing those needs a real image build, which is out of scope here.
#   * the workflow's own shell -- the List channels branch logic lives inline in build.yaml.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

rc=0

# Before trusting anything in test_pending_channels.sh, prove its curl stub actually shadows
# the real curl. If it does not, those tests quietly talk to the live registry and pass for the
# wrong reason -- which has already happened once with a different stubbing approach.
stub="tests/fixtures/bin/curl"
[ -x "$stub" ] || { echo "FATAL: $stub is missing or not executable" >&2; exit 1; }
resolved="$(PATH="$PWD/tests/fixtures/bin:$PATH" command -v curl)"
if [ "$resolved" != "$PWD/tests/fixtures/bin/curl" ]; then
  echo "FATAL: the curl stub does not shadow the real curl (got '$resolved')." >&2
  echo "       pending-channels tests would silently hit the real registry." >&2
  exit 1
fi

for t in tests/test_*.sh; do
  echo "== ${t#tests/test_}"
  "./$t" || rc=1
done

echo "== python"
# Captured rather than piped: a pipe would hand us tail's exit status, not unittest's, and the
# suite would go green on failure.
py_out="$(python3 -m unittest discover -s tests -p 'test_*.py' -q 2>&1)" || rc=1
printf '%s\n' "$py_out" | tail -4
rm -rf tests/__pycache__

echo
[ "$rc" -eq 0 ] && echo "ALL PASSED" || echo "FAILURES -- see above" >&2
exit "$rc"
