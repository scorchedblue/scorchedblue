# ScorchedBlue system recipes.
#
# The filename is load-bearing. ujust does not read this directory; it runs a
# justfile composed at RPM install time, whose final line is
#
#     import? "/usr/share/ublue-os/just/60-custom.just"
#
# That optional import is uBlue's single extension point. Any other name is
# silently ignored -- `import?` does not error on a missing file -- so recipes
# in, say, 60-scorched.just simply never appear in `ujust --list`.
#
# These recipes ORCHESTRATE; they do not implement. Real logic -- argument
# parsing, error handling, state -- belongs in the `scorched` Rust binary,
# where it can be tested. Shell embedded in a .just file cannot be.

# Show ScorchedBlue image provenance.
scorched-info:
    @bootc status --format=yaml | grep -E 'image:|digest:|version:' || bootc status

# Rebase this machine onto a ScorchedBlue tag.
scorched-rebase tag="latest":
    @echo "Rebasing to ghcr.io/scorchedblue/scorchedblue:{{ tag }}"
    @echo "Recovery: bootc rollback, or pick the previous deployment at boot."
    sudo bootc switch ghcr.io/scorchedblue/scorchedblue:{{ tag }}

# --- Homebrew -------------------------------------------------------------
# Provisioning is NOT here: it belongs to scorched-brew-setup.service, which
# runs unattended on first boot and needs root to chown /home/linuxbrew. A
# recipe cannot do that job, because a user who does not know to run it ends up
# with no brew at all. These are the interactive verbs only.
#
# They stay deliberately thin. Once `scorched` exists these become calls into
# it, per the recipes-orchestrate/binary-works split.

# Provision Homebrew now rather than waiting for a reboot.
scorched-brew:
    sudo systemctl start scorched-brew-setup.service
    @echo "brew ready -- open a new shell, then: brew --version"

# Update Homebrew itself and all installed formulae.
scorched-brew-update:
    brew update && brew upgrade

# Remove the Homebrew tree (the image payload stays, so it can be reinstated).
scorched-brew-remove:
    @echo "This deletes /home/linuxbrew and everything installed through brew."
    sudo rm -rf /home/linuxbrew

# --- Claude Code ----------------------------------------------------------
# Deliberately NOT in the image, and deliberately NOT a first-boot unit.
#
# It cannot be installed into /usr in any case: the updater rewrites
# ~/.local/share/claude/versions/ and repoints ~/.local/bin/claude, and /usr is
# read-only. So the only "in the image" option was a payload plus a
# provisioning unit -- and a pinned ~205MB binary that replaces itself within
# days is a poor thing to carry in every image pull.
#
# It is opt-in rather than automatic because this image is public. Homebrew
# provisions unattended because a user who does not know to run a recipe would
# end up with no brew at all; the reverse holds here, and someone installing an
# OS should not silently receive an AI CLI they did not ask for.
#
# The default version and its hash are pinned HERE, in git, so that what this
# installs is reviewable rather than whatever the host serves today -- the same
# discipline as starship and mise. Upstream also publishes a SHA256 per platform
# in manifest.json; that is used only when a different version is asked for,
# and it is weaker, because the manifest is served by the host that serves the
# binary. A pinned hash in the repository is not.
#
# Bumping the default is a deliberate, reviewable change. Left alone it simply
# installs an older build, which then updates itself on first run.

# Install Claude Code into ~/.local, where its updater can reach it.
scorched-claude version="2.1.260":
    #!/usr/bin/bash
    set -euo pipefail
    base="https://downloads.claude.ai/claude-code-releases"
    platform="linux-x64"
    pinned_version="2.1.260"
    pinned_sha256="7a2fdc74b6836ea3d183f665b869f0ee3baebc9713cbebffe5838da4ea7bd82e"
    tmp="$(mktemp -d)"
    trap 'rm -rf "${tmp}"' EXIT
    if [ "{{ version }}" = "${pinned_version}" ]; then
        checksum="${pinned_sha256}"
    else
        echo "Not the pinned version -- falling back to upstream's manifest."
        echo "That hash is served by the same host as the binary, so it proves"
        echo "less than the pinned one. Bump the pin instead, if this is a keeper."
        checksum="$(curl -fsSL "${base}/{{ version }}/manifest.json" \
            | jq -r ".platforms[\"${platform}\"].checksum // empty")"
    fi
    [[ "${checksum}" =~ ^[a-f0-9]{64}$ ]] || {
        echo "No usable checksum for ${platform} at version {{ version }}" >&2
        exit 1
    }
    curl -fsSL -o "${tmp}/claude" "${base}/{{ version }}/${platform}/claude"
    echo "${checksum}  ${tmp}/claude" | sha256sum -c -
    chmod +x "${tmp}/claude"
    # The binary's own `install` sets up the versions directory, the
    # ~/.local/bin launcher and shell integration -- the layout its updater
    # expects. Doing that by hand would be a second, drifting definition of it.
    "${tmp}/claude" install {{ version }}
    echo "Installed. Open a new shell, then: claude --version"

# Update Claude Code. Normally unnecessary -- it updates itself.
scorched-claude-update:
    claude update

# Remove Claude Code and every downloaded version.
scorched-claude-remove:
    @echo "This deletes ~/.local/share/claude and the ~/.local/bin/claude launcher."
    rm -rf "${HOME}/.local/share/claude" "${HOME}/.local/bin/claude"
