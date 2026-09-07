# ScorchedBlue -- core image.
#
# Built from Universal Blue's base-nvidia. The session is Hyprland, so there is
# no desktop environment to inherit and then strip -- a graphical base would
# only add a session we immediately remove. This reverses an earlier choice of
# silverblue-main, which was correct while the session was GNOME.
#
# base-nvidia rather than base-main plus in-house akmods. The open kernel module
# (nvidia.ko reports Dual MIT/GPL), the full userspace and the i686 stack all
# arrive from a build that produces them in lockstep with its own kernel, so the
# kernel-mismatch trap that 20-nvidia.sh existed to catch cannot occur: there is
# one image and one kernel.
#
# It does NOT bring the kernel arguments. base-nvidia:44 ships
# /usr/lib/bootc/kargs.d empty, byte-identical to base-main's -- verified by
# listing both. files/usr/lib/bootc/kargs.d/00-nvidia.toml therefore stays, and
# `just test` still asserts each karg by name.
#
# The base is pinned by digest, never by floating tag, so a build is
# reproducible and a base bump is an explicit, reviewable change.

ARG BASE_IMAGE=ghcr.io/ublue-os/base-nvidia
ARG BASE_DIGEST=sha256:7adbf8d0d7f4eafc90c33bf1dc541988d39770699233ba1a9850a02cd23ea56f

# ---------------------------------------------------------------------------
# Vendored binaries: things Fedora does not package.
#
# starship was dropped from Fedora at F37 and never returned. The usual answer
# is the atim/starship COPR, but a COPR is a build-time dependency on someone
# else's release cadence -- the same class of risk this design rejected when it
# ruled out Hyprland. starship is a single static musl binary with no linkage to
# the base, so pinning a version and a hash is strictly better.
#
# The published .sha256 is a bare hash, not a sha256sum manifest, so it is
# reformatted into one below. The hash is pinned here rather than fetched:
# fetching it from the same host that serves the tarball would verify very
# little.
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE}@${BASE_DIGEST} AS fetch

ARG STARSHIP_VERSION=v1.26.0
ARG STARSHIP_SHA256=b7c232b0e8249d8e55a40beb79c5c43a7d370f3f9408bd215deb0170daeaadf3
ARG STARSHIP_TARBALL=starship-x86_64-unknown-linux-musl.tar.gz

RUN mkdir -p /out \
    && curl -fsSLO "https://github.com/starship/starship/releases/download/${STARSHIP_VERSION}/${STARSHIP_TARBALL}" \
    && echo "${STARSHIP_SHA256}  ${STARSHIP_TARBALL}" | sha256sum -c - \
    && tar -xzf "${STARSHIP_TARBALL}" -C /out starship \
    && /out/starship --version

# mise is not packaged by Fedora at all, so the same pattern applies. Upstream
# publishes a bare static musl binary -- no tarball to unpack, and no linkage to
# the base, which is exactly the property that made this the right route for
# starship.
#
# Upstream also signs SHASUMS256.txt with minisign. The hash is pinned here
# rather than fetched, because fetching it from the host that serves the binary
# would verify very little.
ARG MISE_VERSION=v2026.9.1
ARG MISE_SHA256=fb5111a3e46389bcfc026632e5dc0cfdd45b6565146c21bdb9c7a75ccefbc193
ARG MISE_BINARY=mise-v2026.9.1-linux-x64-musl

RUN curl -fsSL -o /out/mise \
    "https://github.com/jdx/mise/releases/download/${MISE_VERSION}/${MISE_BINARY}" \
    && echo "${MISE_SHA256}  /out/mise" | sha256sum -c - \
    && chmod +x /out/mise \
    && /out/mise --version

# xh is the HTTP client of the work surface, and Fedora does not package it.
# Static musl, built against rustls rather than native-tls, so it carries no
# OpenSSL linkage to the base either.
#
# Upstream publishes no checksum file at all -- not even the bare hash starship
# serves. This one was computed from the downloaded artefact and pinned here,
# which is the same trust position: the hash lives in this repository, where a
# change to it is reviewable, rather than being fetched from the host that
# serves the tarball.
ARG XH_VERSION=v0.26.2
ARG XH_SHA256=8c53b6a23435754f9e2ea8ab8c0d0296a1921404b88132cf9b364ff6e8c22a6e
ARG XH_TARBALL=xh-v0.26.2-x86_64-unknown-linux-musl.tar.gz

RUN curl -fsSLO "https://github.com/ducaale/xh/releases/download/${XH_VERSION}/${XH_TARBALL}" \
    && echo "${XH_SHA256}  ${XH_TARBALL}" | sha256sum -c - \
    && tar -xzf "${XH_TARBALL}" -C /out --strip-components=1 \
    --wildcards '*/xh' \
    && /out/xh --version

# ---------------------------------------------------------------------------
# Homebrew payload.
#
# /home is a symlink to var/home, so an installed brew lives in /var -- state,
# not image. The image can only carry the payload; scorched-brew-setup.service
# unpacks it on first boot.
#
# Built from a pinned, checksummed source tarball rather than Homebrew's
# `curl | bash` installer, for the same reason starship is pinned: an image
# build must not execute whatever a remote host happens to serve today.
#
# This ships a pristine brew (~4MB) rather than a pre-warmed tree with taps
# already fetched. The trade-off is that the first `brew install` fetches the
# formula index over the network.
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE}@${BASE_DIGEST} AS brew

ARG BREW_VERSION=6.0.21
ARG BREW_SHA256=79520db64e9f43d26ecb11fdb443e4a62e6a78b3eab1e84b215e9a35de5dba68

RUN curl -fsSLO "https://github.com/Homebrew/brew/archive/refs/tags/${BREW_VERSION}.tar.gz" \
    && echo "${BREW_SHA256}  ${BREW_VERSION}.tar.gz" | sha256sum -c - \
    && mkdir -p /brewroot/home/linuxbrew/.linuxbrew/Homebrew \
    && tar -xzf "${BREW_VERSION}.tar.gz" --strip-components=1 \
        -C /brewroot/home/linuxbrew/.linuxbrew/Homebrew \
    && mkdir -p /brewroot/home/linuxbrew/.linuxbrew/bin \
    && ln -s ../Homebrew/bin/brew /brewroot/home/linuxbrew/.linuxbrew/bin/brew \
    && test -x /brewroot/home/linuxbrew/.linuxbrew/Homebrew/bin/brew \
    && tar --zstd -cf /homebrew.tar.zst -C /brewroot home/linuxbrew

# ---------------------------------------------------------------------------
# Quickshell, built from source.
#
# Fedora packages quickshell, but as a February 2026 snapshot roughly a minor
# release behind upstream. The shell is written in-house against APIs still
# being learned, so matching the documentation that describes the runtime is
# worth more than avoiding a build -- and vendoring means the QML port lands
# when we choose rather than when Fedora bumps.
#
# This stage MUST use the same base as the final image. Quickshell links private
# Qt APIs and its own docs are explicit that it must be rebuilt against each Qt
# release or it crashes on ABI mismatch. Building against the base the image
# actually ships makes that impossible to get wrong.
#
# Disabled features and why:
#   CRASH_HANDLER  cpptrace is not in Fedora, and vendoring it pulls unpinned
#                  sources over the network at build time
#
# The dependency list is taken from Fedora's own quickshell.spec rather than
# assembled by trial and error -- their packagers already solved this, and each
# guess otherwise costs a full build cycle. Only breakpad, libasan and
# desktop-file-utils are omitted: the first two serve the crash handler and
# sanitizers we do not build, the third only validates a desktop file.
#
# qt6-qtbase-private-devel is not optional. From Qt 6.9 quickshell must depend on
# private modules explicitly, and Qt6QuickPrivate pulls Qt6CorePrivate and
# Qt6GuiPrivate with it. Fedora bundles declarative's private CMake configs into
# the main -devel package but splits qtbase's into a separate one, so omitting it
# fails with "Failed to find required Qt component QuickPrivate" -- naming the
# component asked for rather than the dependency actually missing.
#   X11            this is a Wayland-only system
#   I3 / I3_IPC    not our compositor
# Everything else stays on: wlr-layershell (the bar depends on it), Hyprland
# IPC, StatusNotifier, MPRIS, PAM, polkit and PipeWire.
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE}@${BASE_DIGEST} AS quickshell

ARG QUICKSHELL_VERSION=v0.3.1
ARG QUICKSHELL_SHA256=218f6327293928bcb1f9b25728b336c4ab125f67fe1babd7d47313f890a16c99

RUN dnf5 -y install --setopt=install_weak_deps=False \
        cmake ninja-build gcc-c++ pkgconf-pkg-config \
        qt6-qtbase-devel qt6-qtbase-private-devel \
        qt6-qtdeclarative-devel qt6-qtwayland-devel \
        qt6-qtshadertools-devel qt6-qtsvg-devel \
        cli11-devel spirv-tools libdrm-devel mesa-libgbm-devel \
        wayland-devel wayland-protocols-devel \
        jemalloc-devel pipewire-devel pam-devel polkit-devel glib2-devel

RUN curl -fsSLO "https://github.com/quickshell-mirror/quickshell/archive/refs/tags/${QUICKSHELL_VERSION}.tar.gz" \
    && echo "${QUICKSHELL_SHA256}  ${QUICKSHELL_VERSION}.tar.gz" | sha256sum -c - \
    && tar -xzf "${QUICKSHELL_VERSION}.tar.gz" \
    && cmake -GNinja -B /build -S "quickshell-${QUICKSHELL_VERSION#v}" \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DDISTRIBUTOR=ScorchedBlue \
        -DCRASH_HANDLER=OFF -DX11=OFF -DI3=OFF -DI3_IPC=OFF \
    && cmake --build /build \
    && DESTDIR=/out cmake --install /build \
    && /out/usr/bin/quickshell --version

# ---------------------------------------------------------------------------
# Ghostty, built from source.
#
# The terminal is the work surface, so it belongs in the image rather than in
# Homebrew. Fedora does not package ghostty and there is no static binary to
# vendor -- it links GTK4 -- so this is a builder stage, the same pattern
# quickshell uses.
#
# Zig 0.15.2, NOT 0.16.0. Ghostty's main branch is 1.3.2-dev and declares
# 0.16.0; the 1.3.1 tag declares 0.15.2. Fedora 44 packages both, and a plain
# `dnf install zig` resolves to the newer one, which fails the build with a
# compiler error rather than a version message. Hence the versioned package
# name and the assertion below.
#
# release.files.ghostty.org, not release.ghostty.org -- the latter is the
# announcement site and serves no tarballs. Take the RELEASE tarball rather
# than GitHub's auto-generated one: upstream preprocesses it, which is what
# removes the need for `pandoc` (absent from Fedora 44 entirely) and for
# fetching git dependencies during the build.
#
# Verified with minisign against upstream's published release-signing key as
# well as a pinned sha256. Both, because they answer different questions: the
# signature says upstream produced this artefact, the pinned hash says it is
# the same artefact this repository was reviewed against. The public key is
# allowlisted in .gitleaks.toml -- a generic entropy detector cannot tell a
# minisign public key from a credential.
#
# The tarball is then made to prove it is what the ARGs claim. A pinned hash
# says "this is the file we expected"; reading .version and
# .minimum_zig_version out of build.zig.zon says "and it is the ghostty and
# the zig this stage is documented for", which is what actually goes stale.
#
# zlib-ng-compat-devel, not zlib-devel: Fedora 44 ships no package by the
# latter name.
#
# fetch-zig-cache.sh is upstream's own script for populating the Zig package
# cache, after which `--system` builds with no further network access.
# -Dcpu=baseline because this image runs on machines we do not own.
# -Demit-docs=false skips the manpage/HTML build, which is the part that wants
# pandoc. -Dgtk-x11=false because this is a Wayland-only system.
#
# Image size, measured: P1 (this tree without ghostty) 9,576,726,217 bytes,
# with ghostty 9,611,166,952 -- +34,440,735 bytes, ~32.8 MiB. Nearly all of it
# is the 27MB binary itself. The feared GTK4/libadwaita/GStreamer tax did not
# materialise: gtk4, libadwaita, gstreamer1 and gstreamer1-plugins-base are
# already in the base image, so the only RPM this adds to the final image is
# gtk4-layer-shell (see scripts/12-session.sh). Recorded here because the
# concern was reasonable and the answer is not guessable -- do not re-derive
# it, re-measure it if the base moves.
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE}@${BASE_DIGEST} AS ghostty

ARG GHOSTTY_VERSION=1.3.1
ARG GHOSTTY_SHA256=3349d25600ffbda281197a18314f7d18791969cffe9474f0ff16a45a9ebfccdb
ARG GHOSTTY_MINISIGN_KEY=RWQlAjJC23149WL2sEpT/l0QKy7hMIFhYdQOFy0Z7z7PbneUgvlsnYcV
ARG ZIG_VERSION=0.15.2

RUN dnf5 -y install --setopt=install_weak_deps=False \
        "zig-${ZIG_VERSION}" minisign git \
        pkgconf-pkg-config ncurses gettext blueprint-compiler \
        gtk4-devel libadwaita-devel gtk4-layer-shell-devel \
        gobject-introspection-devel \
        gstreamer1-devel gstreamer1-plugins-base-devel \
        libxkbcommon-devel wayland-devel mesa-libGL-devel \
        fontconfig-devel freetype-devel harfbuzz-devel \
        libpng-devel libxml2-devel oniguruma-devel \
        bzip2-devel expat-devel zlib-ng-compat-devel \
        glslang spirv-tools simdutf-devel

# Assert the compiler, in the shape scripts/12-session.sh uses for the Hyprland
# COPR: a dependency that can drift under us is checked at build time, loudly.
# `zig-0.15.2` above already pins it, so this fires if Fedora ever retires that
# package and the name resolves elsewhere.
RUN got="$(rpm -q --qf '%{version}' zig)"; \
    if [ "${got}" != "${ZIG_VERSION}" ]; then \
        echo "FATAL: zig version drifted." >&2; \
        echo "  expected: ${ZIG_VERSION}" >&2; \
        echo "  got     : ${got}" >&2; \
        echo "Ghostty pins one released Zig. Read build.zig.zon at the ghostty" >&2; \
        echo "tag before touching ZIG_VERSION -- main declares a newer one." >&2; \
        exit 1; \
    fi; \
    echo "OK: zig ${got} matches expected ${ZIG_VERSION}"

RUN curl -fsSLO "https://release.files.ghostty.org/${GHOSTTY_VERSION}/ghostty-${GHOSTTY_VERSION}.tar.gz" \
    && curl -fsSLO "https://release.files.ghostty.org/${GHOSTTY_VERSION}/ghostty-${GHOSTTY_VERSION}.tar.gz.minisig" \
    && minisign -V -m "ghostty-${GHOSTTY_VERSION}.tar.gz" \
        -x "ghostty-${GHOSTTY_VERSION}.tar.gz.minisig" \
        -P "${GHOSTTY_MINISIGN_KEY}" \
    && echo "${GHOSTTY_SHA256}  ghostty-${GHOSTTY_VERSION}.tar.gz" | sha256sum -c - \
    && tar -xzf "ghostty-${GHOSTTY_VERSION}.tar.gz" \
    && cd "ghostty-${GHOSTTY_VERSION}" \
    && src_v="$(sed -n 's/^[[:space:]]*\.version = "\(.*\)",$/\1/p' build.zig.zon)" \
    && src_z="$(sed -n 's/^[[:space:]]*\.minimum_zig_version = "\(.*\)",$/\1/p' build.zig.zon)" \
    && if [ "${src_v}" != "${GHOSTTY_VERSION}" ] || [ "${src_z}" != "${ZIG_VERSION}" ]; then \
        echo "FATAL: the ghostty source does not declare what this stage pins." >&2; \
        echo "  ghostty expected: ${GHOSTTY_VERSION}  declared: ${src_v}" >&2; \
        echo "  zig     expected: ${ZIG_VERSION}  declared: ${src_z}" >&2; \
        exit 1; \
    fi \
    && echo "OK: ghostty ${src_v} declares minimum_zig_version ${src_z}"

ENV ZIG_GLOBAL_CACHE_DIR=/tmp/offline-cache

RUN cd "ghostty-${GHOSTTY_VERSION}" \
    && ./nix/build-support/fetch-zig-cache.sh \
    && DESTDIR=/out zig build --prefix /usr --system /tmp/offline-cache/p \
        -Doptimize=ReleaseFast -Dcpu=baseline \
        -Dversion-string="${GHOSTTY_VERSION}" \
        -Demit-docs=false -Dgtk-x11=false \
    && /out/usr/bin/ghostty --version \
    && /out/usr/bin/ghostty --version | head -1 \
        | grep -qx "Ghostty ${GHOSTTY_VERSION}" \
    && rm -rf /out/usr/include /out/usr/share/pkgconfig

# ---------------------------------------------------------------------------
# The image itself.
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE}@${BASE_DIGEST}

LABEL org.opencontainers.image.title="ScorchedBlue"
LABEL org.opencontainers.image.description="Opinionated, CLI- and container-first Fedora Atomic desktop"
LABEL org.opencontainers.image.source="https://github.com/scorchedblue/scorchedblue"
LABEL org.opencontainers.image.licenses="MIT"

COPY scripts/ /tmp/scripts/
COPY files/ /

RUN /tmp/scripts/10-packages.sh
RUN /tmp/scripts/12-session.sh
RUN /tmp/scripts/15-tailscale.sh
RUN /tmp/scripts/18-performance.sh
RUN /tmp/scripts/20-zoom.sh

COPY --from=fetch /out/starship /usr/bin/starship
COPY --from=fetch /out/mise /usr/bin/mise
COPY --from=fetch /out/xh /usr/bin/xh
COPY --from=brew /homebrew.tar.zst /usr/share/homebrew.tar.zst
COPY --from=quickshell /out/ /
COPY --from=ghostty /out/ /

RUN /tmp/scripts/25-brew.sh
RUN /tmp/scripts/28-branding.sh
RUN /tmp/scripts/30-cleanup.sh
