#!/usr/bin/bash
# Enable first-boot Homebrew provisioning.
#
# Enabled by default deliberately. "Nothing unchosen" means nothing arrives
# unasked -- it does not mean minimal. Homebrew is chosen: it is how CLI tools
# get added without rebuilding and rebooting the OS, which is the whole point of
# a user-space tier on an image-based system.
set -euxo pipefail

systemctl enable scorched-brew-setup.service
