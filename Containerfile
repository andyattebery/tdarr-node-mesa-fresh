# Tdarr node for RDNA 4 (gfx1201, VCN 5.0): the stock image, plus a Mesa above the VCN5
# floor and a ROCm OpenCL runtime for tonemap_opencl.
#
# Base pinned by digest, not by tag: `latest` moves, and a transcode node's driver stack
# should not change under it unannounced.
# Digest below is ghcr.io/haveagitgat/tdarr_node:latest as of 2026-08-17.
FROM ghcr.io/haveagitgat/tdarr_node@sha256:7542459ac5ed5cd299600530e9625b9d590629d5dc391c0016773f5d6aa3fe75

# --- Mesa -------------------------------------------------------------------------------
# Noble ships 25.2.8, which is below the 26.1.2 floor: it misses the gfx1201 VCN unified
# ring-timeout fix and `radeonsi/vcn: Remove encode op_preset overrides`, the latter meaning
# the encoder silently ignores -compression_level on VCN5. See the README for the full list.
#
# NO DEFAULTS, on purpose. The versions live in channels.txt and nowhere else; a default
# here would be a second source of truth that can drift from it, and a bare `docker build .`
# would quietly produce an image nobody chose. Both values are required, and the guard in
# the RUN below fails the build if either is missing.
#
#   ./resolve-channel.sh kisak     -- prints the pair for a channel
#   README.md                      -- the two-line local build
ARG MESA_PPA=
ARG MESA_VERSION=

# --- ROCm -------------------------------------------------------------------------------
# tonemap_opencl needs an OpenCL platform. tonemap_vaapi is NOT an alternative: radeonsi's
# VPP reports "VAAPI driver doesn't support HDR" (that filter is Intel iHD only), and
# libplacebo/Vulkan works but benchmarked slower than OpenCL on this card.
ARG ROCM_VERSION=7.2.4

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN set -eux; \
    # Required, not defaulted -- see the ARG block. An unset MESA_VERSION would make the apt
    # pin match nothing, which apt treats as success, so this has to be caught up front.
    test -n "${MESA_PPA}" \
      || { echo "FATAL: MESA_PPA is unset. Pass --build-arg MESA_PPA=... (see channels.txt)"; exit 1; }; \
    test -n "${MESA_VERSION}" \
      || { echo "FATAL: MESA_VERSION is unset. Pass --build-arg MESA_VERSION=... (see channels.txt)"; exit 1; }; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    # All four are already in the base image; listed so this does not silently depend on
    # that staying true. Because they are pre-existing, none of them is purged afterwards --
    # stripping something the base shipped is not this image's business.
    apt-get install -y --no-install-recommends ca-certificates curl gnupg software-properties-common; \
    \
    # VDPAU is unused here (the node encodes through VA-API) and the PPAs version it
    # inconsistently -- mesarc lags it at 25.2.5 while shipping 26.2.0 for everything else,
    # which would force a downgrade or strand a symlink into a libgallium that is gone.
    # Simulated against the running node: removes exactly mesa-vdpau-drivers and
    # vdpau-driver-all, nothing else.
    apt-get purge -y mesa-vdpau-drivers; \
    \
    add-apt-repository -y "${MESA_PPA}"; \
    \
    # Pin by version rather than by archive origin, so MESA_PPA stays a free parameter:
    # only the Mesa packages carry this exact version string, and 1001 permits a downgrade
    # if a PPA is ever behind noble's own Mesa.
    printf 'Package: *\nPin: version %s\nPin-Priority: 1001\n' "${MESA_VERSION}" \
      > /etc/apt/preferences.d/99-mesa-pin; \
    \
    install -m 0755 -d /etc/apt/keyrings; \
    curl -fsSL https://repo.radeon.com/rocm/rocm.gpg.key \
      | gpg --dearmor -o /etc/apt/keyrings/rocm.gpg; \
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/${ROCM_VERSION} noble main" \
      > /etc/apt/sources.list.d/rocm.list; \
    \
    apt-get update; \
    # dist-upgrade, not upgrade: from Mesa 26.0 the VA driver was folded into
    # mesa-libgallium, which Breaks/Replaces mesa-va-drivers (<< 26.0.0~). Resolving that
    # requires removing a package, which plain `upgrade` refuses to do.
    #
    # Be clear about the blast radius: this is NOT Mesa-only. It also pulls whatever noble
    # security and -updates packages are current at build time, so two builds a month apart
    # differ by more than the Mesa pin. That is accepted -- a long-lived node wants those
    # -- but it means the image is reproducible only via its output digest, not
    # by rebuilding. The Mesa version, which is the measurement-relevant variable, is pinned
    # and recorded in /etc/tdarr-node-mesa-fresh.build.
    apt-get dist-upgrade -y; \
    apt-get install -y --no-install-recommends rocm-opencl-runtime; \
    \
    # NO autoremove. Simulated against the running node it would remove 150+ packages the
    # base image ships -- libavdevice60, libavfilter9, libplacebo338, libass9, the whole GTK
    # stack -- because the base leaves much of its multimedia tree marked auto. It would gut
    # the image's own ffmpeg and HandBrake for the sake of a smaller layer.
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# --- Build-time gates -------------------------------------------------------------------
# An apt version pin that matches nothing is a no-op, not an error: without these the image
# would build clean, ship 25.2.8, and pass every runtime check against the wrong driver.
RUN set -eux; \
    ldconfig; \
    got="$(dpkg-query -W -f='${Version}' mesa-libgallium)"; \
    test "${got}" = "${MESA_VERSION}" \
      || { echo "FATAL: mesa-libgallium is ${got}, expected ${MESA_VERSION}"; exit 1; }; \
    # Follows the symlink. mesa-va-drivers carries no versioned dependency on
    # mesa-libgallium, so a mismatched pair yields a dangling link and silent VA-API death.
    test -e /usr/lib/x86_64-linux-gnu/dri/radeonsi_drv_video.so \
      || { echo "FATAL: radeonsi_drv_video.so missing or dangling"; exit 1; }; \
    # The ICD filename carries the ROCm build (amdocl64_70204_93.icd), so match a glob,
    # never a fixed name. The ICD itself just says "libamdocl64.so", which resolves through
    # the /etc/ld.so.conf.d/10-rocm-opencl.conf the package ships -- so check both halves.
    ls /etc/OpenCL/vendors/amdocl64*.icd >/dev/null 2>&1 \
      || { echo "FATAL: no AMD OpenCL ICD registered"; exit 1; }; \
    ldconfig -p | grep -q libamdocl64.so \
      || { echo "FATAL: libamdocl64.so not on the loader path"; exit 1; }

# Stamped from the installed package, not echoed back from the ARG, so the label describes
# what is actually in the image.
RUN printf 'MESA_VERSION=%s\nMESA_PPA=%s\nROCM_VERSION=%s\n' \
      "$(dpkg-query -W -f='${Version}' mesa-libgallium)" "${MESA_PPA}" "${ROCM_VERSION}" \
      > /etc/tdarr-node-mesa-fresh.build

LABEL org.opencontainers.image.source="https://github.com/andyattebery/tdarr-node-mesa-fresh"
LABEL org.opencontainers.image.description="Tdarr node with fresh Mesa (VA-API on gfx1201) and ROCm OpenCL"
LABEL org.opencontainers.image.base.name="ghcr.io/haveagitgat/tdarr_node"
