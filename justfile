# ScorchedBlue -- task runner.
#
# Everything CI runs lives in the `ci` recipe, and CI calls that recipe, so the
# two cannot drift.

image := "localhost/scorchedblue"
tag := "latest"
registry := "ghcr.io/scorchedblue/scorchedblue"

default:
    @just --list

# Install pinned tooling.
setup:
    mise install
    git config core.hooksPath .githooks

fmt:
    shfmt -w -i 4 -ci scripts/*.sh files/usr/libexec/*

# files/usr/libexec/* is included deliberately. Those are the scripts that
# actually run on the machine -- the greeter and the performance unit -- and
# they were unlinted while the build-time scripts were not. The greeter in
# particular is the one program where a mistake means nobody can log in.
lint:
    shfmt -d -i 4 -ci scripts/*.sh files/usr/libexec/*
    shellcheck scripts/*.sh files/usr/libexec/*

# Build the image. Sources of truth for versions live in the Containerfile ARGs.
build:
    podman build -t {{ image }}:{{ tag }} .

# Assertions against the built image. Requires `just build` first.
test: build
    #!/usr/bin/bash
    set -euxo pipefail
    # Pin the image this run is verifying. `test` depends on `build`, so every
    # invocation re-tags -- and anything else that builds concurrently moves the
    # tag out from under these assertions. Without the check at the end of this
    # recipe, "the image I verified" and "the image under the tag" can differ
    # and nothing says so. Compare IDs, exactly as `just vm` does, and for the
    # same reason: a substitution under the same tag is otherwise silent.
    verified="$(podman image inspect {{ image }}:{{ tag }} --format '{{{{.Id}}}}')"
    # bootc must consider this a valid bootable container.
    podman run --rm {{ image }}:{{ tag }} bootc container lint
    # The NVIDIA userspace must be present, not just the kernel module -- a kmod
    # with no userspace yields no nvidia-smi, no GL, and no working session.
    # These come from base-nvidia now rather than from akmods RPMs we install,
    # so this asserts the base is the one we think it is.
    podman run --rm {{ image }}:{{ tag }} bash -c 'command -v nvidia-smi'
    podman run --rm {{ image }}:{{ tag }} rpm -q \
        kmod-nvidia nvidia-kmod-common nvidia-driver nvidia-driver-libs nvidia-modprobe
    # 32-bit GL must be present or 32-bit Steam titles will not run.
    podman run --rm {{ image }}:{{ tag }} bash -c \
        'rpm -qa --qf "%{name}.%{arch}\n" | grep -q "^nvidia-driver-libs.i686$" && echo "32-bit GL: ok"'
    # The driver is inert without the kargs that let it reach the GPU. No RPM
    # ships them and neither does base-nvidia: its /usr/lib/bootc/kargs.d is
    # empty, identical to base-main's, so the move to an NVIDIA base did not
    # retire files/usr/lib/bootc/kargs.d/00-nvidia.toml. Absent them nouveau
    # claims the card from the initrd, nvidia.ko cannot attach, and the machine
    # boots to a black screen with dead VTs: a fully valid image that cannot
    # draw. Assert each karg by name.
    podman run --rm {{ image }}:{{ tag }} bash -c \
        'for k in rd.driver.blacklist=nouveau modprobe.blacklist=nouveau nvidia-drm.modeset=1 initcall_blacklist=simpledrm_platform_driver_init; do \
             grep -qsF "$k" /usr/lib/bootc/kargs.d/*.toml || { echo "MISSING KARG: $k"; exit 1; }; \
         done; echo "nvidia kargs: ok"'
    # The kmod must exist for the kernel this image actually ships. Taking the
    # driver from the base makes lockstep structural rather than something to
    # police -- one image, one kernel -- which is why scripts/20-nvidia.sh and
    # its AKMODS_TAG check are gone. This is what remains of that assertion, and
    # it is what would fire if a future base ever shipped the two out of step.
    podman run --rm {{ image }}:{{ tag }} bash -c \
        'k="$(rpm -q --qf "%{version}-%{release}.%{arch}" kernel-core)"; \
         ls "/usr/lib/modules/$k/extra/nvidia/nvidia.ko"* >/dev/null \
         && echo "kmod matches shipped kernel $k: ok"'
    # ...and it must be the OPEN kmod. Nothing visible says which flavour a base
    # ships: base-nvidia names the package `kmod-nvidia` either way, and its RPM
    # License tag reads "NVIDIA License" even for the open modules. The only
    # thing that distinguishes them is the module's own MODULE_LICENSE -- the
    # open kmod declares "Dual MIT/GPL", the proprietary one declares "NVIDIA".
    # So assert that string by name: a base bump that silently swapped flavours
    # would otherwise pass every other NVIDIA check in this recipe.
    podman run --rm {{ image }}:{{ tag }} bash -c \
        'k="$(rpm -q --qf "%{version}-%{release}.%{arch}" kernel-core)"; \
         lic="$(modinfo -k "$k" -F license nvidia)"; \
         [ "$lic" = "Dual MIT/GPL" ] || { \
             echo "nvidia.ko declares \"$lic\"; expected \"Dual MIT/GPL\" (open kmod)" >&2; \
             exit 1; }; \
         echo "nvidia driver flavour: open kmod, Dual MIT/GPL: ok"'
    # Vendored binary landed and runs.
    podman run --rm {{ image }}:{{ tag }} starship --version
    # Image-tier tools are present.
    podman run --rm {{ image }}:{{ tag }} bash -c 'for b in chezmoi nvim delta rg fd tmux jq; do command -v $b >/dev/null || { echo "MISSING: $b"; exit 1; }; done; echo "image-tier tools: ok"'
    # fastfetch is image-tier for a reason: it answers "which image am I on"
    # in a rescue shell, before Homebrew exists. Assert the binary AND that the
    # shipped config parses -- a jsonc syntax error or an unknown module name
    # makes fastfetch exit non-zero, and nothing else in the build would catch
    # it. --pipe because a build container has no tty; verified to still exit 0
    # with TERM=dumb and stdout redirected.
    podman run --rm {{ image }}:{{ tag }} bash -c \
        'command -v fastfetch >/dev/null \
         && fastfetch --config /etc/fastfetch/config.jsonc --pipe >/dev/null \
         && echo "fastfetch: ok"'
    # The config names a logo file by absolute path. If it is missing fastfetch
    # falls back to a built-in logo and still exits 0, so the branding would
    # vanish silently -- assert the file landed.
    podman run --rm {{ image }}:{{ tag }} \
        test -f /usr/share/fastfetch/logos/scorchedblue.txt
    # base-nvidia must not have dragged in a desktop environment.
    podman run --rm {{ image }}:{{ tag }} bash -c \
        '! rpm -q gnome-shell gdm mutter >/dev/null 2>&1 && echo "no inherited desktop: ok"'
    # The session: compositor, portal and greeter.
    podman run --rm {{ image }}:{{ tag }} bash -c \
        'command -v Hyprland >/dev/null && rpm -q xdg-desktop-portal-hyprland >/dev/null \
         && systemctl is-enabled greetd.service >/dev/null && echo "session: ok"'
    # greetd must launch tuigreet, not its stock agreety text greeter. That
    # default looks near-identical to a getty prompt on a screenshot, so an
    # unconfigured greeter is easy to mistake for a broken one.
    podman run --rm {{ image }}:{{ tag }} bash -c \
        'grep -q scorched-greeter /etc/greetd/config.toml && echo "greeter configured: ok"'
    # The greeter is the one process where a bad argument means nobody can log
    # in, so assert the wrapper is present, executable and parses. greetd's
    # `command` is a bare path precisely so that argument splitting cannot be
    # the thing that breaks it.
    podman run --rm {{ image }}:{{ tag }} bash -c \
        'test -x /usr/libexec/scorched-greeter \
         && bash -n /usr/libexec/scorched-greeter \
         && grep -q "exec /usr/bin/tuigreet" /usr/libexec/scorched-greeter \
         && echo "greeter wrapper: ok"'
    # A session must exist for the greeter to offer.
    podman run --rm {{ image }}:{{ tag }} bash -c \
        'test -f /usr/share/wayland-sessions/hyprland.desktop && echo "wayland session: ok"'
    # The portal order is load-bearing -- hyprland must win ScreenCast, or the
    # region picker is unreachable and the pivot bought nothing.
    podman run --rm {{ image }}:{{ tag }} bash -c \
        'grep -q "^default=hyprland;" /etc/xdg-desktop-portal/portals.conf && echo "portal order: ok"'
    # Correct portal order is not sufficient. xdg-desktop-portal.service has
    # Requisite=graphical-session.target, which sets RefuseManualStart=yes and
    # so can only be reached as a dependency. Hyprland starts no such target --
    # gnome-session used to -- so without this unit every portal request dies
    # with "startup job failed" and screen sharing is simply unavailable. The
    # session looks perfectly healthy until something asks for a portal.
    # XDG_RUNTIME_DIR because `systemd-analyze verify --user` refuses to
    # initialise a user manager without one, and a build container has none:
    # "Failed to lookup RuntimeDirectory path: No such device or address".
    # --user is still required -- without it the search path is the system one
    # and graphical-session.target does not resolve.
    podman run --rm {{ image }}:{{ tag }} bash -c \
        'export XDG_RUNTIME_DIR=/tmp; \
         systemd-analyze verify --user /usr/lib/systemd/user/hyprland-session.target \
         && grep -q "^BindsTo=graphical-session.target$" \
                /usr/lib/systemd/user/hyprland-session.target \
         && echo "session target: ok"'
    # Performance mode must be installed AND enabled. An enabled-but-absent
    # unit and an installed-but-disabled one both look fine in a file listing
    # and both mean the machine quietly runs in powersave.
    podman run --rm {{ image }}:{{ tag }} bash -c \
        'test -x /usr/libexec/scorched-performance \
         && bash -n /usr/libexec/scorched-performance \
         && systemctl is-enabled scorched-performance.service >/dev/null \
         && echo "performance mode: ok"'
    # Both knobs, not just the governor: on intel_pstate the energy/performance
    # preference holds clocks back on its own, which is the usual reason this
    # change appears to do nothing.
    podman run --rm {{ image }}:{{ tag }} bash -c \
        'grep -q scaling_governor /usr/libexec/scorched-performance \
         && grep -q energy_performance_preference /usr/libexec/scorched-performance \
         && echo "performance knobs: ok"'
    # The shell serves notifications and the launcher, so mako and fuzzel must
    # not be present. mako especially: it ships a D-Bus service file, so an
    # installed-but-unstarted mako is still activated on demand and takes
    # org.freedesktop.Notifications, after which the shell receives nothing and
    # logs nothing. Assert the package AND its activation file are gone.
    podman run --rm {{ image }}:{{ tag }} bash -c \
        '! rpm -q mako fuzzel >/dev/null 2>&1 \
         && test ! -e /usr/share/dbus-1/services/fr.emersion.mako.service \
         && echo "no notification daemon conflict: ok"'
    # Quickshell, built against this image's Qt. It links private Qt APIs, so a
    # mismatch here is a crash at runtime rather than a build error.
    podman run --rm {{ image }}:{{ tag }} quickshell --version
    # Layershell is what the bar anchors to; without it the shell cannot exist.
    podman run --rm {{ image }}:{{ tag }} bash -c \
        'quickshell --help >/dev/null 2>&1 && echo "quickshell: ok"'
    # Leaf tools must NOT be in the image -- they belong to the Homebrew tier.
    # httpie in particular drags a Python stack into /usr if it leaks back in.
    podman run --rm {{ image }}:{{ tag }} bash -c \
        '! rpm -q httpie gh zoxide bat tealdeer >/dev/null 2>&1 && echo "leaf tools absent: ok"'
    podman run --rm {{ image }}:{{ tag }} bash -c \
        '! rpm -q python3-pip >/dev/null 2>&1 && echo "no python3-pip: ok"'
    # Weak deps are off deliberately: neovim Recommends tree-sitter-cli, which
    # drags 337MB of nodejs and C toolchain into a runtime image. If any of these
    # reappear, install_weak_deps has leaked back on.
    podman run --rm {{ image }}:{{ tag }} bash -c \
        '! rpm -q gcc make binutils nodejs22 tree-sitter-cli >/dev/null 2>&1 && echo "no toolchain leak: ok"'
    # ... but the clipboard bridge must survive, or yanking silently breaks.
    podman run --rm {{ image }}:{{ tag }} rpm -q wl-clipboard inotify-tools >/dev/null \
        && echo "wayland clipboard: ok"
    # Our ujust recipes must actually be reachable. ujust runs a composed
    # justfile whose only extension point is an OPTIONAL import of
    # 60-custom.just -- any other filename is ignored without error, so this
    # fails silently rather than loudly. Assert the recipes are listed.
    podman run --rm {{ image }}:{{ tag }} bash -c \
        'ujust --list | grep -q scorched-info && echo "ujust recipes: ok"'
    # The Claude recipes are opt-in tooling, so nothing else would notice if the
    # import silently stopped exposing them.
    podman run --rm {{ image }}:{{ tag }} bash -c \
        'ujust --list | grep -q scorched-claude && echo "claude recipes: ok"'
    # They are recipes, not an installed binary. Claude must NOT be in the
    # image: its updater rewrites ~/.local, /usr is read-only, and a public OS
    # image should not ship an AI CLI to people who did not ask for one.
    podman run --rm {{ image }}:{{ tag }} bash -c \
        '! command -v claude >/dev/null && echo "claude correctly absent from the image: ok"'
    # Tailscale is first-class: daemon present, CLI present, unit enabled.
    podman run --rm {{ image }}:{{ tag }} bash -c \
        'command -v tailscale >/dev/null && command -v tailscaled >/dev/null \
         && systemctl is-enabled tailscaled.service >/dev/null \
         && echo "tailscale: ok"'
    # The image must carry no identity -- no auth key, no node state.
    podman run --rm {{ image }}:{{ tag }} bash -c \
        '[ ! -e /var/lib/tailscale/tailscaled.state ] && echo "tailscale carries no identity: ok"'
    # The work surface. These define the image as a terminal-first workstation,
    # so they must be present before Homebrew has provisioned anything -- a user
    # who has to wait for brew to get `rg` has not been handed the product.
    podman run --rm {{ image }}:{{ tag }} bash -c \
        'for b in git gh just mise xh bat eza rg fd delta starship jq yq vim wget; do \
             command -v "$b" >/dev/null || { echo "missing: $b" >&2; exit 1; }; \
         done; echo "work surface: ok"'
    # yq must be mikefarah/yq. The unrelated kislyuk/yq of the same name is a
    # Python wrapper around jq, and a swap would be invisible to `command -v`
    # while quietly putting a runtime stack in /usr.
    podman run --rm {{ image }}:{{ tag }} bash -c \
        'yq --version | grep -q mikefarah && echo "yq is the Go implementation: ok"'
    # mise and xh are vendored, not packaged -- assert they actually run. A
    # binary built against the wrong libc would be present and non-functional,
    # and a `command -v` check would not notice.
    podman run --rm {{ image }}:{{ tag }} mise --version
    podman run --rm {{ image }}:{{ tag }} xh --version
    # httpie must stay out: it drags a python runtime stack into /usr, which is
    # what the admission test exists to exclude. xh is its replacement.
    podman run --rm {{ image }}:{{ tag }} bash -c \
        '! rpm -q httpie >/dev/null 2>&1 && ! command -v http >/dev/null \
         && echo "no python http stack: ok"'
    # just in the image must match what mise pins for the repositories, or a
    # machine and a checkout can disagree about the same recipe.
    podman run --rm {{ image }}:{{ tag }} bash -c \
        '[ "$(just --version | cut -d" " -f2)" = "1.57.0" ] && echo "just version matches the mise pin: ok"'
    # The boot menu must name the image. ostree builds the BLS title as
    # "${PRETTY_NAME} (ostree:N)" at deployment time, so a wrong PRETTY_NAME is
    # invisible until a machine reboots with two deployments and cannot tell
    # them apart -- exactly when the menu matters.
    podman run --rm {{ image }}:{{ tag }} bash -c \
        'grep -q "^PRETTY_NAME=\"ScorchedBlue " /usr/lib/os-release \
         && grep -q "^VARIANT_ID=scorchedblue$" /usr/lib/os-release \
         && echo "boot identity: ok"'
    # ...but the base must stay identifiable. Downstream tooling parses these to
    # decide what it is running on, so the branding above must not have touched
    # them. This is Fedora 44 with our layers on top and must keep saying so.
    podman run --rm {{ image }}:{{ tag }} bash -c \
        'grep -q "^ID=fedora$" /usr/lib/os-release \
         && grep -q "^VERSION_ID=44$" /usr/lib/os-release \
         && echo "base still identifiable: ok"'
    # Downstream tooling probes this file to decide whether the host is a
    # Universal Blue image. Without it, provisioning silently skips the desktop
    # phase and its whole Brewfile group -- a skip, not an error.
    podman run --rm {{ image }}:{{ tag }} bash -c \
        'jq -e "has(\"image-name\")" /usr/share/ublue-os/image-info.json >/dev/null && echo "image-info: ok"'
    # Homebrew payload and its first-boot unit.
    podman run --rm {{ image }}:{{ tag }} test -f /usr/share/homebrew.tar.zst
    podman run --rm {{ image }}:{{ tag }} test -x /usr/libexec/scorched-brew-setup
    podman run --rm {{ image }}:{{ tag }} systemctl is-enabled scorched-brew-setup.service
    # Exercise the provisioning script the way first boot will: create the user
    # it chowns to, run it, then run it again to prove it is idempotent. This is
    # the closest thing to a boot test that does not need root.
    podman run --rm {{ image }}:{{ tag }} bash -c '\
        useradd -m -u 1000 tester 2>/dev/null || true; \
        /usr/libexec/scorched-brew-setup >/dev/null; \
        test -x /home/linuxbrew/.linuxbrew/bin/brew || { echo "brew not executable"; exit 1; }; \
        [ "$(stat -c %u /home/linuxbrew/.linuxbrew)" = 1000 ] || { echo "wrong owner"; exit 1; }; \
        /usr/libexec/scorched-brew-setup | grep -q "already present" || { echo "not idempotent"; exit 1; }; \
        echo "brew provisioning: ok"'
    # The payload must actually contain a runnable brew, not just unpack cleanly.
    podman run --rm {{ image }}:{{ tag }} bash -c \
        'tar --zstd -tf /usr/share/homebrew.tar.zst | grep -q "^home/linuxbrew/.linuxbrew/bin/brew$" && echo "brew payload: ok"'
    # Last, because a pass means nothing if the tag no longer names the image
    # that passed. Anything else building concurrently moves it, and the next
    # command someone runs against the tag -- `podman save`, `just vm`, a rebase
    # -- would then use an image nothing verified.
    current="$(podman image inspect {{ image }}:{{ tag }} --format '{{{{.Id}}}}')"
    [ "$current" = "$verified" ] || {
        echo "{{ image }}:{{ tag }} moved during this run: verified ${verified}, tag now ${current}" >&2
        exit 1
    }
    echo "verified image: ${verified}"

# Vulnerability scan.
#
# trivy cannot see rootless podman images without a socket, and enabling
# podman.socket permanently is a system change this recipe has no business
# making. An ephemeral `podman system service` speaks the Docker API, so
# DOCKER_HOST + --image-src docker works locally and in CI with no persistent
# state. The socket lives in XDG_RUNTIME_DIR because unix socket paths cap at
# ~108 characters, and is unique per invocation so two concurrent runs cannot
# delete each other's socket via their EXIT traps.
#
# sysroot/ostree/repo is skipped: it is the content-addressed object store, so
# scanning it re-reports every binary a second time under an unreadable hash.
#
# Report-only, deliberately. The findings are inherited from the base image
# (cosign, from ublue-os-signing) and we cannot fix them here -- failing CI on
# them would mean a permanently red pipeline for something outside our control.
# `just security-diff` is what answers the question that matters: did WE add any?

# Scan the image for HIGH/CRITICAL vulnerabilities (report-only).
security: build
    #!/usr/bin/bash
    set -euo pipefail
    # GitHub runners do not reliably have XDG_RUNTIME_DIR or /run/user/<uid>,
    # so fall back to /tmp. Both must stay short: unix socket paths cap at
    # ~108 characters. Unique per invocation so concurrent runs cannot delete
    # each other's socket via their EXIT traps.
    rt="${XDG_RUNTIME_DIR:-}"
    [ -d "$rt" ] || rt="/tmp"
    sock="$rt/bfos-$$.sock"
    rm -f "$sock"
    podman system service --time=0 "unix://$sock" >/dev/null 2>&1 &
    svc=$!
    trap 'kill $svc 2>/dev/null || true; rm -f "$sock"' EXIT
    for _ in $(seq 1 20); do [ -S "$sock" ] && break; sleep 0.5; done
    [ -S "$sock" ] || { echo "podman socket did not start" >&2; exit 1; }
    # --timeout: trivy defaults to 5m, which a ~10GB image exceeds on CI-grade
    # I/O -- it dies mid-layer with "context deadline exceeded".
    DOCKER_HOST="unix://$sock" trivy image --image-src docker \
        --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed \
        --skip-dirs sysroot/ostree/repo --timeout 30m \
        {{ image }}:{{ tag }}

# Did our layers introduce any vulnerability the base did not already have?
# This is the question worth failing on.

# CVEs we introduced that the base image does not already carry.
security-diff: build
    #!/usr/bin/bash
    set -euo pipefail
    # GitHub runners do not reliably have XDG_RUNTIME_DIR or /run/user/<uid>,
    # so fall back to /tmp. Both must stay short: unix socket paths cap at
    # ~108 characters. Unique per invocation so concurrent runs cannot delete
    # each other's socket via their EXIT traps.
    rt="${XDG_RUNTIME_DIR:-}"
    [ -d "$rt" ] || rt="/tmp"
    sock="$rt/bfos-$$.sock"
    rm -f "$sock"
    podman system service --time=0 "unix://$sock" >/dev/null 2>&1 &
    svc=$!
    trap 'kill $svc 2>/dev/null || true; rm -f "$sock"' EXIT
    for _ in $(seq 1 20); do [ -S "$sock" ] && break; sleep 0.5; done
    [ -S "$sock" ] || { echo "podman socket did not start" >&2; exit 1; }
    base="$(grep -oP '(?<=^ARG BASE_IMAGE=).*' Containerfile)@$(grep -oP '(?<=^ARG BASE_DIGEST=).*' Containerfile)"
    scan() {
        DOCKER_HOST="unix://$sock" trivy image --image-src docker --quiet \
            --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed \
            --skip-dirs sysroot/ostree/repo --timeout 30m --format json "$1" \
            | jq -r '.Results[]?.Vulnerabilities[]?.VulnerabilityID' | sort -u
    }
    # Sequentially, into files: trivy's local cache is not safe for concurrent
    # use, and process substitution would run both scans at once ("cache may be
    # in use by another process").
    tmp="$(mktemp -d)"
    trap 'kill $svc 2>/dev/null || true; rm -f "$sock"; rm -rf "$tmp"' EXIT
    echo "scanning base..."  ; scan "$base"              > "$tmp/base.txt"
    echo "scanning image..." ; scan {{ image }}:{{ tag }} > "$tmp/img.txt"
    echo
    echo "base CVEs: $(wc -l < "$tmp/base.txt")   image CVEs: $(wc -l < "$tmp/img.txt")"
    echo "CVEs present in ScorchedBlue but not in the base:"
    if comm -13 "$tmp/base.txt" "$tmp/img.txt" | grep .; then
        echo "^ introduced by our layers"
        exit 1
    else
        echo "  (none -- our layers introduced nothing)"
    fi

# What changed relative to the base image.
diff: build
    #!/usr/bin/bash
    set -euo pipefail
    base="$(grep -oP '(?<=^ARG BASE_IMAGE=).*' Containerfile)@$(grep -oP '(?<=^ARG BASE_DIGEST=).*' Containerfile)"
    # 2>/dev/null: rpm scriptlet chatter on stderr otherwise interleaves into
    # the package list and shows up as bogus additions.
    diff <(podman run --rm "${base}" rpm -qa --qf '%{name}\n' 2>/dev/null | sort -u) \
         <(podman run --rm {{ image }}:{{ tag }} rpm -qa --qf '%{name}\n' 2>/dev/null | sort -u) || true

# Bootable qcow2 for VM testing (needs root; Fedora has no default rootfs type).
#
# bootc-image-builder is pinned by digest, per the security posture that pins
# container images by digest rather than tag. There is no Fedora-published
# builder -- quay.io/fedora/bootc-image-builder does not exist -- so the CentOS
# one is the supported route for Fedora bootc images.
vm: build
    #!/usr/bin/bash
    set -euo pipefail
    mkdir -p output
    # bootc-image-builder runs as root and therefore reads root's container
    # storage, but `just build` produces the image rootless. Stream it across
    # rather than rebuilding under sudo -- piping avoids a ~10GB temp file.
    # Compare IDs, not mere existence: a stale copy under the same tag would
    # otherwise be reused silently, and the disk image would be built from
    # whatever was last copied rather than what was just built.
    want="$(podman image inspect {{ image }}:{{ tag }} --format '{{{{.Id}}}}')"
    have="$(sudo podman image inspect {{ image }}:{{ tag }} --format '{{{{.Id}}}}' 2>/dev/null || true)"
    if [ "$want" != "$have" ]; then
        echo "copying image into root storage (this takes a few minutes)..."
        podman save {{ image }}:{{ tag }} | sudo podman load
    fi
    # A fresh image has no user account. The GNOME build got one from
    # gnome-initial-setup; greetd has no equivalent, so without this the VM
    # boots to a login prompt nothing can log into. Real hardware is unaffected
    # -- `bootc switch` keeps the accounts already on the machine -- but
    # install media will need a real answer for this. See planning.
    #
    # The password is generated per run and printed, so no credential is ever
    # committed. This config is for the throwaway VM only and never reaches the
    # image.
    # Bounded input deliberately: reading /dev/urandom straight into `head`
    # hands `tr` a SIGPIPE as soon as head has enough, and pipefail turns that
    # into a failed recipe reporting a bare exit 141. 512 bytes because tr -dc
    # discards most of them.
    vmpass="$(head -c 512 /dev/urandom | tr -dc 'a-z0-9' | cut -c1-16)"
    # An ssh key as well as a password: the VM is a development target for
    # scorched-desktop, and pushing config over ssh is the whole loop. Falls
    # back to password-only if no key exists rather than failing the build.
    sshkey=""
    [ -f ~/.ssh/id_ed25519.pub ] && sshkey="$(cat ~/.ssh/id_ed25519.pub)"
    cat > output/vm-config.toml <<EOF
    [[customizations.user]]
    name = "test"
    password = "${vmpass}"
    groups = ["wheel"]
    key = "${sshkey}"
    EOF
    sed -i 's/^    //' output/vm-config.toml
    echo "VM login: test / ${vmpass}"
    sudo podman run --rm --privileged --security-opt label=type:unconfined_t \
        -v ./output:/output -v ./output/vm-config.toml:/config.toml:ro \
        -v /var/lib/containers/storage:/var/lib/containers/storage \
        quay.io/centos-bootc/bootc-image-builder@sha256:2b52843ea2bfda73b0a08d97e76b734393b1d3a804681b9fabb26723bd3a2f0b \
        --type qcow2 --rootfs btrfs --local {{ image }}:{{ tag }}

# Rebase this machine. `bootc rollback` is the recovery path.
rebase:
    sudo bootc switch {{ registry }}:{{ tag }}

clean:
    -podman rmi {{ image }}:{{ tag }}
    rm -rf output

# Everything CI runs. CI calls this recipe.
# Full-history secret scan. The pre-commit hook runs `protect --staged`, which
# only ever sees one commit; this is what catches anything already landed.
secrets:
    gitleaks detect --no-banner --redact

ci: lint secrets test security
