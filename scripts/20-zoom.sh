#!/usr/bin/bash
# Zoom, as a Flatpak.
#
# Conferencing that works out of the box, shipped as a Flatpak rather than an
# RPM: it is a sandboxed GUI application, which is where the placement policy
# sends it, and it keeps a proprietary blob out of /usr.
#
# base-nvidia already ships flatpak with the flathub remote pre-configured
# (flatpak-add-fedora-repos.service, enabled by default) -- nothing to add
# there. A Flatpak system install itself lives under /var/lib/flatpak,
# deployment state rather than image content, the same reason
# scorched-brew-setup.service exists for Homebrew. So this only enables the
# first-boot unit that pulls Zoom once the network is up; the actual install
# happens in files/usr/libexec/scorched-zoom-setup.
set -euxo pipefail

systemctl enable scorched-zoom-setup.service
