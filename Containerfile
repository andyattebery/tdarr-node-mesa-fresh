# Tdarr node for RDNA 4 (gfx1201, VCN 5.0): the stock image, plus a Mesa above the VCN5 floor.
#
# The base arrives as repo:version@digest. The digest is what resolves; the tag rides along
# so build logs, `docker history` and the base.name label read as a version, not a hash.
#
# Pinned by digest and not by the version tag alone, because a tag can be re-pushed -- which
# would make `hold` in base.txt mean nothing. Note what this does NOT buy: the dist-upgrade
# below floats every noble package, so this is not a reproducible build. It pins the one
# input that is free to pin.
#
# The value lives in base.txt and nowhere else. refresh-base.py moves it daily, the same way
# channels.txt follows the PPAs.
#
# No default, for the same reason MESA_* has none -- but note the failure mode differs. An
# empty value fails while resolving the FROM itself -- "base name (${BASE_IMAGE}) should not
# be blank" -- rather than with the readable FATAL below, because nothing runs before FROM.
#
# BuildKit warns InvalidDefaultArgInFrom on every build because of this. That is the warning
# firing on the intended design, not a defect: giving it a default to quiet the lint is
# exactly the silent-wrong-base failure the empty value exists to prevent. Leave it.
#
#   ./resolve-base.sh              -- prints base_image and tdarr_version
ARG BASE_IMAGE=
FROM ${BASE_IMAGE}

# --- Mesa -------------------------------------------------------------------------------
# Noble ships 25.2.8, which is below the 26.1.2 floor: it misses the gfx1201 VCN unified
# ring-timeout fix and `radeonsi/vcn: Remove encode op_preset overrides`, the latter meaning
# the encoder silently ignores -compression_level on VCN5. See the README for the full list.
#
# NO DEFAULTS, on purpose. The Mesa versions live in channels.txt and nowhere else; a default
# here would be a second source of truth that can drift from it, and a bare `docker build .`
# would quietly produce an image nobody chose. Both values are required, and the guard in
# the RUN below fails the build if either is missing.
#
#   ./resolve-channel.sh kisak     -- prints the pair for a channel
#   README.md                      -- the local build
ARG MESA_PPA=
ARG MESA_VERSION=

# --- Upstream ---------------------------------------------------------------------------
# Which Tdarr release BASE_IMAGE is. Echoed into the stamp and used in the exact image tag.
# Unlike MESA_VERSION this cannot be read back out of the image at build time -- a label is
# not visible from inside a RUN -- so resolve-base.sh is what guarantees it matches the
# digest above, by cross-checking the two against the registry before the pin is written.
ARG TDARR_VERSION=

# BASE_IMAGE is declared above FROM, which puts it in the global scope -- NOT in this build
# stage. Without this bare re-declaration ${BASE_IMAGE} below expands to the empty string and
# both the stamp and the base.name label ship blank, with nothing failing to say so.
ARG BASE_IMAGE

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN set -eux; \
    # Required, not defaulted -- see the ARG block. An unset MESA_VERSION would make the apt
    # pin match nothing, which apt treats as success, so this has to be caught up front.
    test -n "${MESA_PPA}" \
      || { echo "FATAL: MESA_PPA is unset. Pass --build-arg MESA_PPA=... (see channels.txt)"; exit 1; }; \
    test -n "${MESA_VERSION}" \
      || { echo "FATAL: MESA_VERSION is unset. Pass --build-arg MESA_VERSION=... (see channels.txt)"; exit 1; }; \
    test -n "${TDARR_VERSION}" \
      || { echo "FATAL: TDARR_VERSION is unset. Pass --build-arg TDARR_VERSION=... (see base.txt)"; exit 1; }; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    # All three are already in the base image; listed so this does not silently depend on
    # that staying true. Because they are pre-existing, none of them is purged afterwards --
    # stripping something the base shipped is not this image's business.
    apt-get install -y --no-install-recommends ca-certificates gnupg software-properties-common; \
    \
    # VDPAU is unused here (the node encodes through VA-API) and the PPAs version it
    # inconsistently -- mesarc has left it several releases behind the rest of its Mesa stack,
    # which would force a downgrade or strand a symlink into a libgallium that is gone. No
    # version named here on purpose: the pins now follow the PPAs, so a number would go stale.
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
    # add-apt-repository already refreshes, but only as an implementation detail of
    # software-properties-common. Cheap to not depend on that.
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
      || { echo "FATAL: radeonsi_drv_video.so missing or dangling"; exit 1; }

# The Mesa version is stamped from the installed package, not echoed back from the ARG, so
# it describes what is actually in the image. The other three cannot be: MESA_PPA is not
# recorded anywhere queryable after the build, and the base's identity is a manifest property
# the container cannot see. Those are echoed, and this comment is here so nobody reads the
# whole file as read-back evidence.
RUN printf 'MESA_VERSION=%s\nMESA_PPA=%s\nTDARR_VERSION=%s\nBASE_IMAGE=%s\n' \
      "$(dpkg-query -W -f='${Version}' mesa-libgallium)" "${MESA_PPA}" \
      "${TDARR_VERSION}" "${BASE_IMAGE}" \
      > /etc/tdarr-node-mesa-fresh.build

LABEL org.opencontainers.image.source="https://github.com/andyattebery/tdarr-node-mesa-fresh"
LABEL org.opencontainers.image.description="Tdarr node with fresh Mesa (VA-API on gfx1201)"
LABEL org.opencontainers.image.base.name="${BASE_IMAGE}"
