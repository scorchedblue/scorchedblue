# ScorchedBlue -- core image.
#
# Built from Universal Blue's base-main. The session is Hyprland, so there is no
# desktop environment to inherit and then strip -- a graphical base would only
# add a session we immediately remove. This reverses an earlier choice of
# silverblue-main, which was correct while the session was GNOME.
#
# The base is pinned by digest, never by floating tag, so a build is
# reproducible and a base bump is an explicit, reviewable change.

ARG BASE_IMAGE=ghcr.io/ublue-os/base-main
ARG BASE_DIGEST=sha256:9342a22b7eabca2504f08697bb43141db4e425485bb604e8ed8166b83e550d37

# akmods must be built against the same kernel as the base. uBlue publishes them
# in lockstep; 20-nvidia.sh asserts the match rather than trusting it.
ARG AKMODS_IMAGE=ghcr.io/ublue-os/akmods-nvidia-open
ARG AKMODS_TAG=main-44

FROM ${AKMODS_IMAGE}:${AKMODS_TAG} AS akmods

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

# The akmods RPMs are bind-mounted rather than COPYed. A COPY would add a ~470MB
# layer that the later cleanup cannot reclaim -- image layers are additive, so
# `rm` in a subsequent RUN hides files without shrinking anything.
RUN --mount=type=bind,from=akmods,src=/rpms,dst=/tmp/akmods/rpms \
    /tmp/scripts/20-nvidia.sh

COPY --from=fetch /out/starship /usr/bin/starship
COPY --from=fetch /out/mise /usr/bin/mise
COPY --from=brew /homebrew.tar.zst /usr/share/homebrew.tar.zst
COPY --from=quickshell /out/ /

RUN /tmp/scripts/25-brew.sh
RUN /tmp/scripts/28-branding.sh
RUN /tmp/scripts/30-cleanup.sh
