#!/usr/bin/env python3
"""Point base.txt at the image ghcr.io/haveagitgat/tdarr_node:latest currently resolves to.

    ./refresh-base.py --check     report only; exit 1 if behind
    ./refresh-base.py --write     rewrite the row; new version on stdout ('' if unchanged),
                                  report on stderr

Why the pin carries a digest and not just a version tag
-------------------------------------------------------
Two reasons, and neither is paranoia about the publisher. First, `hold` in base.txt is
meaningless without a digest: a version tag can be re-pushed, so a row frozen at :2.86.01
could still change underneath a deliberate rollback. Second, deciding "has upstream moved"
from tag *names* means ordering 2.86.01, 2.00.15.1, 1.99.04, 2.13.01_ffmpeg5, dev and
latest_ffmpeg5 against each other -- refresh-channels.py explicitly refused to write a version
comparator, and this script has no more business doing it. Resolving :latest to a digest turns
the question into string equality, which cannot be subtly wrong.

Why the version name is read from the image and then checked against the registry
----------------------------------------------------------------------------------
The digest says *what* moved but not what to call it, and the tag is what goes in the image
tags this repo publishes. The amd64 config carries
`org.opencontainers.image.version = dev_2.86.01_2026_08_05T06_27_22z`, so the name is derivable
from the image itself -- but a label is free-form text a publisher can change at will, so the
name it yields is then looked up as a tag and required to resolve to the same digest. One of
those alone would be a guess; together they are a fact.

Rejected: enumerating all ~143 tags and matching digests. That is 143 requests, and GHCR
returns tags in push order, which a re-push of an old tag would disturb -- so it is both slower
and less reliable than asking the image what it is.

Failure posture
---------------
Every surprise dies. A label that no longer parses, a version tag that resolves elsewhere, an
index with no single amd64 entry: each of those means the assumption behind this script has
changed, and the right outcome is a red scheduled run that ships nothing, not a pin written on
a guess. Same posture as refresh-channels.py.
"""

import argparse
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

TIMEOUT = 30

# The four an OCI registry may answer a manifest request with. Without all four, GHCR can
# return a schema this script does not expect.
ACCEPT = ", ".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
])

# The tag whose movement defines "upstream released something". Not `dev`.
TRACK = "latest"

# The only value field 4 may take. A closed set: a typo'd freeze marker must not silently read
# as "not frozen" and let the bot overwrite a deliberate pin.
HOLD = "hold"

# Matches the existing column layout in base.txt.
ROW_FMT = "%-32s %-8s %s"

DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
VERSION_RE = re.compile(r"\d+\.\d+\.\d+(?:\.\d+)?")


def die(msg):
    print(f"refresh-base: {msg}", file=sys.stderr)
    raise SystemExit(1)


def parse(path):
    """Return (lines, index, image, version, digest, held, trailing_comment)."""
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()

    rows = []
    for i, line in enumerate(lines):
        body, sep, comment = line.partition("#")
        if not body.split():
            continue
        fields = body.split()
        if len(fields) not in (3, 4):
            die(f"{path}:{i + 1}: needs 3 or 4 fields (image version digest [{HOLD}]), "
                f"got {len(fields)}")
        held = False
        if len(fields) == 4:
            if fields[3] != HOLD:
                die(f"{path}:{i + 1}: field 4 is '{fields[3]}', the only allowed value is "
                    f"'{HOLD}'")
            held = True
        rows.append((i, fields[0], fields[1], fields[2], held, sep + comment if sep else ""))

    # Exactly one, not "the first one" -- a second row would be silently ignored.
    if len(rows) != 1:
        die(f"{path} must hold exactly one row, found {len(rows)}")

    i, image, version, digest, held, comment = rows[0]
    if not DIGEST_RE.match(digest):
        die(f"{path}:{i + 1}: '{digest}' is not a sha256:<64 hex> reference")
    return lines, i, image, version, digest, held, comment


class Registry:
    """The handful of ghcr.io reads this needs, with one anonymous pull token."""

    def __init__(self, image):
        registry, _, repo = image.partition("/")
        # Refusing is better than untested support: every other registry differs in how it
        # hands out tokens, and a wrong guess here writes a bad pin.
        if registry != "ghcr.io":
            die(f"'{image}' is not on ghcr.io; this script only speaks to ghcr.io")
        if not repo:
            die(f"cannot parse '{image}' as <registry>/<repository>")
        self.repo = repo
        self.token = self._token()

    def _get(self, url, headers=None, method="GET"):
        req = urllib.request.Request(url, headers=headers or {}, method=method)
        try:
            return urllib.request.urlopen(req, timeout=TIMEOUT)
        except (urllib.error.URLError, OSError) as exc:
            die(f"{method} {url} failed: {exc}")

    def _token(self):
        url = "https://ghcr.io/token?" + urllib.parse.urlencode({
            "scope": f"repository:{self.repo}:pull",
            "service": "ghcr.io",
        })
        with self._get(url) as resp:
            try:
                return json.load(resp)["token"]
            except (json.JSONDecodeError, KeyError) as exc:
                die(f"no pull token for {self.repo}: {exc}")

    def _auth(self, accept=None):
        h = {"Authorization": f"Bearer {self.token}"}
        if accept:
            h["Accept"] = accept
        return h

    def digest_of(self, ref):
        """The manifest digest a tag resolves to, or None if the tag does not exist."""
        url = f"https://ghcr.io/v2/{self.repo}/manifests/{ref}"
        req = urllib.request.Request(url, headers=self._auth(ACCEPT), method="HEAD")
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
                return resp.headers.get("Docker-Content-Digest")
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                return None
            die(f"HEAD {url} failed: {exc}")
        except (urllib.error.URLError, OSError) as exc:
            die(f"HEAD {url} failed: {exc}")

    def json_at(self, ref, accept=ACCEPT):
        url = f"https://ghcr.io/v2/{self.repo}/manifests/{ref}"
        with self._get(url, self._auth(accept)) as resp:
            try:
                return json.load(resp)
            except json.JSONDecodeError as exc:
                die(f"GET {url} returned unparseable JSON: {exc}")

    def blob(self, digest):
        url = f"https://ghcr.io/v2/{self.repo}/blobs/{digest}"
        with self._get(url, self._auth()) as resp:
            try:
                return json.load(resp)
            except json.JSONDecodeError as exc:
                die(f"GET {url} returned unparseable JSON: {exc}")


def version_of(reg, digest):
    """The name upstream gives the image at `digest`, confirmed against the registry."""
    index = reg.json_at(digest)

    manifests = index.get("manifests")
    if manifests is None:
        # A single-arch image: the config is right here.
        amd64 = digest
    else:
        # Not `manifests[0]`. Alongside amd64 and arm64 this index carries attestation
        # manifests with platform unknown/unknown, which must not be mistaken for the image.
        hits = [m["digest"] for m in manifests
                if m.get("platform", {}).get("architecture") == "amd64"
                and m.get("platform", {}).get("os") == "linux"]
        if len(hits) != 1:
            die(f"expected exactly 1 linux/amd64 manifest in {digest}, got {len(hits)}")
        amd64 = hits[0]

    manifest = reg.json_at(amd64, "application/vnd.oci.image.manifest.v1+json")
    try:
        config = reg.blob(manifest["config"]["digest"])
        label = config["config"]["Labels"]["org.opencontainers.image.version"]
    except (KeyError, TypeError) as exc:
        die(f"no org.opencontainers.image.version label on {amd64}: {exc}")

    match = VERSION_RE.search(label)
    if not match:
        die(f"no x.y.z version in the label '{label}'; the upstream naming scheme changed")
    version = match.group(0)

    # The half that makes the label a fact rather than a claim.
    confirmed = reg.digest_of(version)
    if confirmed is None:
        die(f"the label says '{label}' -> '{version}', but no such tag exists upstream")
    if confirmed != digest:
        die(f"tag '{version}' resolves to {confirmed}, not the {digest} that :{TRACK} "
            f"resolves to; refusing to name this build")
    return version


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="report only, write nothing")
    mode.add_argument("--write", action="store_true", help="rewrite the row if it moved")
    ap.add_argument("--file", default="base.txt")
    args = ap.parse_args()

    lines, i, image, version, digest, held, comment = parse(args.file)

    if held:
        print(f"  {image}  {version}  [{HOLD}] left alone", file=sys.stderr)
        if args.write:
            print("", end="")
        return 0

    reg = Registry(image)
    latest = reg.digest_of(TRACK)
    if latest is None:
        die(f"{image}:{TRACK} does not exist")

    if latest == digest:
        print(f"  {image}  {version}  up to date", file=sys.stderr)
        if args.write:
            print("", end="")
        return 0

    new_version = version_of(reg, latest)
    print(f"  {image}  {version} ({digest[:14]}...)\n"
          f"           -> {new_version} ({latest[:14]}...)  CHANGED", file=sys.stderr)

    if args.write:
        # Rebuild the row rather than substituting into it: same reason as
        # refresh-channels.py, plus rebuilding is what restores the column alignment.
        lines[i] = (ROW_FMT % (image, new_version, latest)).rstrip() + comment
        with open(args.file, "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")
        # stdout is the machine-readable half: the workflow reads it to decide whether the
        # base moved, without parsing the report above.
        print(new_version)
        return 0

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
