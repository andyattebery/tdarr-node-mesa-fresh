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

## Which Mesa

`MESA_PPA` and `MESA_VERSION` are build arguments and **only valid as a pair** — a version
string exists in exactly one PPA. Verified present for noble/amd64 on 2026-08-17:

| PPA | Version | Notes |
| --- | --- | --- |
| `ppa:kisak/kisak-mesa` | `26.1.7~kisak1~n` | **Default.** Tagged stable point release. |
| `ppa:ernstp/mesarc` | `26.2.0+git2608121546.5cdfde45036~n~mesarc0` | `staging/26.2` HEAD. |

The default is 26.1.7 because Mesa's own 26.2.0 release notes say:

> Mesa 26.2.0 is a new development release. People who are concerned with stability and
> reliability should stick with a previous release or wait for Mesa 26.2.1.

**26.2.1 does not exist yet.** mesarc's build is not an arbitrary snapshot — its commit
`5cdfde45036` is `staging/26.2` HEAD exactly, i.e. 26.2.1-in-progress, and its earlier
`~rc2`/`~rc3` publications match the `mesa-26.2.0-rc2`/`-rc3` tags commit-for-commit. It is
therefore the closest thing to a stable 26.2 that exists, and it is one dispatch input away.

26.2 is worth wanting for one reason: `va: Set contiguous_planes for DMA-BUF imported
surfaces`, which may unblock a zero-copy filter path. That benefit is **unverified** — do not
switch the default until it is measured.

To build 26.2, run the workflow with both inputs changed together.

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
  inconsistently (25.2.5 while everything else is 26.2.0), which would otherwise force a
  downgrade or strand a symlink.
- **An apt version pin that matches nothing is a no-op, not an error.** Without the build-time
  assertion the image would build clean, ship 25.2.8, and pass every runtime check against the
  wrong driver.
- **The OpenCL ICD filename carries the ROCm build** (`amdocl64_70204_93.icd`), so the check
  globs rather than naming it.

## Verifying a built image

Needs `--device /dev/dri --device /dev/kfd`. `vainfo` and `clinfo` are both already present.

```bash
podman run --rm --device /dev/dri --device /dev/kfd --security-opt label=disable \
  ghcr.io/andyattebery/tdarr-node-mesa-fresh:latest \
  bash -c 'cat /etc/tdarr-node-mesa-fresh.build; vainfo --display drm --device /dev/dri/renderD128; clinfo -l'
```

Expected: the Mesa version matching what was built, `VAProfileHEVCMain10` with
`VAEntrypointEncSlice`, and an OpenCL device reporting **gfx1201**.
