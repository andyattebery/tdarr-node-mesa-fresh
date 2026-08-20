#!/usr/bin/env python3
"""Point each channel in channels.txt at the version its PPA currently publishes.

    ./refresh-channels.py --check     report only; exit 1 if anything is behind
    ./refresh-channels.py --write     rewrite the version fields; JSON array of changed
                                      channel names on stdout, report on stderr

Why this queries *binaries* and not sources
-------------------------------------------
A Launchpad source publication does not mean the package is installable. On 2026-08-20 mesarc's
26.2.1 source was Published at 10:06 UTC while its amd64 build was still `Needs building` -- an
updater reading sources would have written a version that apt cannot resolve, and the build would
have failed for a reason that looks nothing like the cause. `getPublishedBinaries` for
noble/amd64 is exactly the question "can this be installed", which is the only question the pin
cares about.

Why mesa-libgallium is the probe package
----------------------------------------
It is the same package the Containerfile asserts against after installing. Probing anything else
would let the updater and the build gate disagree; probing this one makes them agree by
construction.

Why `status=Published` needs no version comparison
--------------------------------------------------
Superseded publications are excluded, which leaves exactly one entry per PPA. There is no "newest"
to compute, so there is no version-ordering code here to get subtly wrong -- Debian version
ordering is genuinely hard and this script would be a bad place to reimplement it. If that
assumption ever stops holding, the count assertion below fails loudly rather than picking one.
"""

import argparse
import json
import sys
import urllib.error
import urllib.parse
import urllib.request

LP = "https://api.launchpad.net/1.0"
SERIES = f"{LP}/ubuntu/noble/amd64"
PROBE = "mesa-libgallium"
TIMEOUT = 30

# The only value field 4 may take. A closed set, like the channel names themselves: a typo'd
# freeze marker must not silently read as "not frozen" and let the bot overwrite a deliberate pin.
HOLD = "hold"

# Matches the existing column layout: field 2 at column 12, field 3 at column 35.
ROW_FMT = "%-10s %-22s %s"


def die(msg):
    print(f"refresh-channels: {msg}", file=sys.stderr)
    raise SystemExit(1)


def api_path(ppa):
    """ppa:kisak/kisak-mesa -> https://api.launchpad.net/1.0/~kisak/+archive/ubuntu/kisak-mesa"""
    if not ppa.startswith("ppa:"):
        die(f"'{ppa}' is not a ppa: reference")
    owner, _, name = ppa[4:].partition("/")
    if not owner or not name:
        die(f"cannot parse '{ppa}' as ppa:<owner>/<name>")
    return f"{LP}/~{owner}/+archive/ubuntu/{name}"


def published_version(ppa, channel):
    """The version of PROBE that this PPA currently has installable on noble/amd64."""
    url = api_path(ppa) + "?" + urllib.parse.urlencode({
        "ws.op": "getPublishedBinaries",
        "binary_name": PROBE,
        "exact_match": "true",
        "status": "Published",
        "distro_arch_series": SERIES,
    })
    try:
        with urllib.request.urlopen(url, timeout=TIMEOUT) as resp:
            entries = json.load(resp).get("entries", [])
    except (urllib.error.URLError, json.JSONDecodeError, OSError) as exc:
        die(f"{channel}: querying {ppa} failed: {exc}")

    # Not `entries[0]`. If a PPA ever has two Published binaries for one package on one arch, the
    # premise of this script is wrong and picking either one would be a guess.
    if len(entries) != 1:
        die(f"{channel}: expected exactly 1 published {PROBE} in {ppa} for noble/amd64, "
            f"got {len(entries)}")

    version = entries[0]["binary_package_version"]

    # The same guard resolve-channel.sh applies when reading the file, applied here before
    # writing it: if a row's ppa field is ever edited to point somewhere else, this catches it
    # before a mesarc version can land in the kisak row and ship an image tagged :kisak carrying
    # the wrong driver.
    if channel not in version:
        die(f"{channel}: {ppa} publishes '{version}', which does not contain '{channel}'; "
            f"wrong ppa for this row?")
    return version


def parse(path):
    """Yield (index, channel, ppa, version, held, trailing_comment) for each data line."""
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()

    rows = []
    for i, line in enumerate(lines):
        body, sep, comment = line.partition("#")
        if not body.split():
            continue
        fields = body.split()
        if len(fields) not in (3, 4):
            die(f"{path}:{i + 1}: needs 3 or 4 fields (channel ppa version [{HOLD}]), "
                f"got {len(fields)}")
        held = False
        if len(fields) == 4:
            if fields[3] != HOLD:
                die(f"{path}:{i + 1}: field 4 is '{fields[3]}', the only allowed value is '{HOLD}'")
            held = True
        rows.append((i, fields[0], fields[1], fields[2], held, sep + comment if sep else ""))

    if not rows:
        die(f"{path} lists no channels")

    names = [r[1] for r in rows]
    if len(set(names)) != len(names):
        die(f"duplicate channel name in {path}")
    return lines, rows


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="report only, write nothing")
    mode.add_argument("--write", action="store_true", help="rewrite changed version fields")
    ap.add_argument("--file", default="channels.txt")
    args = ap.parse_args()

    lines, rows = parse(args.file)
    changed = []

    for i, channel, ppa, version, held, comment in rows:
        if held:
            print(f"  {channel:<8} {version}  [{HOLD}] left alone", file=sys.stderr)
            continue

        latest = published_version(ppa, channel)
        if latest == version:
            print(f"  {channel:<8} {version}  up to date", file=sys.stderr)
            continue

        print(f"  {channel:<8} {version}\n           -> {latest}  CHANGED", file=sys.stderr)
        changed.append(channel)
        # Rebuild the row rather than substituting the version in place: these strings contain
        # '+' and '.', so a regex replacement would need escaping to be correct, and a literal
        # one would still not restore the column alignment.
        lines[i] = (ROW_FMT % (channel, ppa, latest)).rstrip() + comment

    if args.write:
        if changed:
            with open(args.file, "w", encoding="utf-8") as fh:
                fh.write("\n".join(lines) + "\n")
        # stdout is the machine-readable half, so the workflow can read it without parsing the
        # report above.
        print(json.dumps(changed))
        return 0

    return 1 if changed else 0


if __name__ == "__main__":
    raise SystemExit(main())
