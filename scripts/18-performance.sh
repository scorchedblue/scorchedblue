#!/usr/bin/bash
# Always-on performance mode.
#
# ScorchedBlue targets desktops. There is no battery to preserve here, so the
# kernel's default of trading latency for power is the wrong trade on every
# machine this image is meant for.
#
# The unit does the work and is deliberately tolerant of hardware that has
# fewer knobs -- see /usr/libexec/scorched-performance. This script only
# installs it, because the alternative to a unit is a kernel argument, and a
# karg cannot set the energy/performance preference, which is half of what
# actually matters on intel_pstate.

set -euxo pipefail

systemctl enable scorched-performance.service
