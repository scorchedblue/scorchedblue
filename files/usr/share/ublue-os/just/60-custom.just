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
