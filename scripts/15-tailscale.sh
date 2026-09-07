#!/usr/bin/bash
# Tailscale, as a first-class part of the OS.
#
# From Tailscale's own repository rather than Fedora's. Fedora carries
# tailscale (1.98.8-1.fc44 at time of writing) but trails upstream by several
# minor versions, and this is the vendor's own repository -- first-party, GPG
# signed, with repo_gpgcheck as well as gpgcheck.
#
# This ships the daemon and the CLI. It ships NO identity: no auth key, no
# tailnet, no node state. Authentication is `tailscale up` on the machine, and
# the resulting state lives in /var/lib/tailscale, which is deployment state
# rather than image content.
set -euxo pipefail

dnf5 -y config-manager addrepo \
    --from-repofile=https://pkgs.tailscale.com/stable/fedora/tailscale.repo

dnf5 -y install --setopt=install_weak_deps=False tailscale

# Enabled by default: "first-class" means the daemon is up on first boot and
# `tailscale up` is the only step left. An unauthenticated tailscaled is inert
# -- it joins nothing until someone authenticates it.
systemctl enable tailscaled.service

dnf5 clean all
rm -rf /var/cache/libdnf5/* /var/lib/dnf/repos
