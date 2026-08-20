# tdarr-node-mesa-fresh

The stock Tdarr node image, plus the two things an **RDNA 4** card needs for VA-API
transcoding and does not have: a **Mesa new enough to drive gfx1201 correctly**, and a
**ROCm OpenCL runtime** for `tonemap_opencl`.

Written against a **Radeon RX 9070 XT (Navi 48, gfx1201, VCN 5.0)**. Nothing here is specific
to a particular deployment — it is the stock image plus two packages.

```
ghcr.io/andyattebery/tdarr-node-mesa-fresh
```

## Why this exists

The stock image (`ghcr.io/haveagitgat/tdarr_node`) is **Ubuntu 24.04.4 with Mesa 25.2.8**, and
it *does* already encode `hevc_vaapi` and `av1_vaapi` on this card — RDNA 4 support landed in
Mesa 25.0. So this is not about making the GPU work at all. Two specific gaps remain:

**1. Mesa 25.2.8 is below the floor for VCN 5.0.** Missing from it:

- the fix for a bug report naming this exact GPU — `[radeonsi/VCN] RX 9070 XT (Navi 48,
  gfx1201): VCN unified ring timeout during VAAPI HEVC encode` (Mesa 26.1.2)
- `radeonsi/vcn: Remove encode op_preset overrides` and
  `radeonsi/vcn: Don't force balance encode preset with sao on VCN5` (26.1.0) — without these
  the encoder **silently ignores `-compression_level`**, so quality/speed tuning does nothing
  and does not tell you it did nothing
- an AV1/HEVC encode coded-buffer overrun that segfaults the client (26.1.6)
- the `ac_video_dec` decode rewrite (26.1.0), in the hot path for 4K HEVC input

**2. There is no OpenCL platform**, so `tonemap_opencl` cannot initialise
(`Failed to get number of OpenCL platforms: -1001`).

Neither alternative tonemapper is a substitute, and both were measured rather than assumed:

- `tonemap_vaapi` → **`VAAPI driver doesn't support HDR`**. That VPP capability is Intel iHD
  only; radeonsi advertises `VAProfileNone: VAEntrypointVideoProc` with no HDR filter.
- `libplacebo` on Vulkan works, given an ffmpeg built `--enable-vulkan --enable-libplacebo`
  (RADV enumerates `RADV GFX1201` fine), but benchmarked **slower than OpenCL** here. It is
  also a different tone-mapping algorithm, so it will not match `tonemap_cuda` output if you
  run a mixed AMD/NVIDIA fleet and expect one tone curve across it.

## ffmpeg is deliberately untouched

This image adds a **driver stack**, not an encoder. The base image's bundled ffmpeg is left
exactly as it is.

That matters because a Mesa new enough for gfx1201 does nothing on its own if ffmpeg lacks the
AMD encoders — `hevc_vaapi`, `av1_vaapi`, and `tonemap_opencl` all have to be compiled in. If
yours is not, supply one by bind-mounting it and pointing Tdarr's `ffmpegPath` at it, which
keeps the encoder and the driver as separately upgradable pieces. A jellyfin-ffmpeg build
configured `--enable-vaapi --enable-opencl --enable-vulkan` is one way to get there.

## Channels

Which Mesa the image carries is a **channel**, and every channel is defined in one place —
[`channels.txt`](channels.txt). Nothing else in this repo pins a version.

| Channel | What it tracks |
| --- | --- |
| `kisak` | Mesa's **tagged point releases**, from `ppa:kisak/kisak-mesa`. |
| `mesarc` | Snapshots of Mesa's **current staging branch** (`staging/26.2` as of 2026-08), from `ppa:ernstp/mesarc`. |

**Every channel is built on every push**, independently, and each is published under its own
tags. There is no default channel and no channel is privileged in the registry — which one you
run is decided where you deploy, not here.

The two differ in how their version moves, not in rank. `kisak` publishes when Mesa tags a point
release, so its pin sits still in between. `mesarc` republishes snapshots of a branch, so its pin
moves more often and can carry commits that are in no release yet. 26.2.1 shipped on 2026-08-20
as, in Mesa's own words, *"a bug fix release which fixes bugs found since the 26.2.0 release"* —
so the 26.2 line has a stable point release behind it now, and mesarc tracks the branch
continuing past it.

26.2 is worth wanting for one reason: `va: Set contiguous_planes for DMA-BUF imported
surfaces`, which may unblock a zero-copy filter path. That benefit is **unverified** — measure
it before promoting.

### Building a channel

A push to `main` builds **every** channel in `channels.txt`, as independent matrix jobs. To
build one on demand, run the workflow and pick it from `mesa_channel` (`all` is the default).

A **daily scheduled run** does something different. It first runs `refresh-channels.py`, which
asks each PPA what it currently has installable on noble/amd64, writes that into `channels.txt`
and commits it — then builds only the channels whose version actually moved. Most days nothing
moves, and the run finishes green having built nothing. That is the normal outcome, not a
misfire.

The refresh and the build share one run because a push made with `GITHUB_TOKEN` does not trigger
`on: push`: a bot commit cannot start a build of its own, so the run that writes the pin has to
be the run that builds it. To rehearse that path without waiting for cron, dispatch the workflow
with `refresh` ticked — it behaves exactly as the scheduled run does, including ignoring
`mesa_channel`.

Channels do not `fail-fast` on each other, and that is load-bearing rather than tidy: a PPA can
publish a build that trips one of the Containerfile's gates, and when that happens the other
channel must still build and publish. Expect a run with one red leg and one green — that is the
design working, not a broken repo.

Locally — no process substitution, so this works in any shell:

```sh
set -- $(grep '^kisak' channels.txt)
docker build --build-arg MESA_PPA="$2" --build-arg MESA_VERSION="$3" -t tdarr-node-mesa-fresh .
```

`./resolve-channel.sh <channel>` prints the same values, and is what the workflow uses.

There are no `ARG` defaults: a build with no channel fails rather than silently picking one.

### Tags

    :<channel>                          moving pointer for that channel
    :<channel>-<version>                the exact build ('~' and '+' become '-')
    :<git sha>

Run `./resolve-channel.sh <channel>` to see the exact tags a build would push.

**There is deliberately no `:latest`.** With several channels published side by side it would
just be whichever built most recently, which is not what the name suggests. Pull a channel tag
when you want that driver line, or a digest when you want exactly one build.

### Adding a channel, or freezing one

Adding a channel is an edit to `channels.txt` alone — a row naming the channel, its PPA and any
version, since the next refresh corrects it — plus its name in the workflow's dropdown, which
GitHub requires to be a literal list. Nothing here decides what runs in production; consumers
pull a channel tag or a digest, so switching driver line is their edit, not this one.

Re-pinning, though, is no longer something you do: the daily refresh writes whatever the PPA
publishes. A hand edit still works, but only until the next run overwrites it. To make a pin
stick — to roll back, or to sit out a bad publication — add `hold` as a fourth field. Here the
channel is being kept on an older release while a newer one is already in the PPA:

    kisak      ppa:kisak/kisak-mesa   26.1.6~kisak1~n   hold

The refresh skips a held row entirely and reports it as held. `hold` is the only value that
field accepts; anything else fails the build rather than quietly reading as "not held".

## Packaging traps this image works around

Each of these was found by reading the archive indexes, and each would otherwise produce a
clean-looking image with a broken driver.

- **From Mesa 26.0 the VA driver moved into `mesa-libgallium`.** kisak has no
  `mesa-va-drivers` package at all; its `mesa-libgallium` carries
  `Provides: mesa-va-drivers, va-driver` with `Breaks`/`Replaces: mesa-va-drivers (<< 26.0.0~)`.
  mesarc still ships a separate `mesa-va-drivers`. A hardcoded package list cannot serve both,
  which is why the build pins **by version** and uses `dist-upgrade`.
- **`dist-upgrade`, not `upgrade`** — resolving that `Breaks`/`Replaces` requires removing a
  package, which plain `upgrade` refuses to do.
- **`mesa-va-drivers` has no versioned dependency on `mesa-libgallium`.** A mismatched pair
  leaves `radeonsi_drv_video.so` dangling into a `libgallium-<ver>.so` that is gone, and apt
  will not stop you. The build tests that the symlink resolves.
- **`mesa-vdpau-drivers` is purged.** VDPAU is unused here, and mesarc versions it
  inconsistently — it sits several releases behind the rest of that PPA's Mesa stack — which
  would otherwise force a downgrade or strand a symlink.
- **An apt version pin that matches nothing is a no-op, not an error.** Without the build-time
  assertion the image would build clean, ship 25.2.8, and pass every runtime check against the
  wrong driver.
- **The OpenCL ICD filename carries the ROCm build** (`amdocl64_70204_93.icd`), so the check
  globs rather than naming it.

## Verifying a built image

Needs `--device /dev/dri --device /dev/kfd`. `vainfo` and `clinfo` are both already present.

```bash
podman run --rm --device /dev/dri --device /dev/kfd --security-opt label=disable \
  ghcr.io/andyattebery/tdarr-node-mesa-fresh:kisak \
  bash -c 'cat /etc/tdarr-node-mesa-fresh.build; vainfo --display drm --device /dev/dri/renderD128; clinfo -l'
```

Expected: the Mesa version matching what was built, `VAProfileHEVCMain10` with
`VAEntrypointEncSlice`, and an OpenCL device reporting **gfx1201**.
