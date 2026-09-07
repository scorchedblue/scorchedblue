#!/usr/bin/bash
# Leave nothing behind that would inflate the image or leak into the deployment.
set -euxo pipefail

dnf5 clean all
rm -rf /tmp/akmods /tmp/scripts

# /var must be empty in a bootc image: anything left here becomes part of the
# deployment's initial /var rather than the immutable /usr, and will not be
# updated on subsequent image bumps. bootc's var-tmpfiles lint flags whatever
# remains without a matching tmpfiles.d entry.
rm -rf /var/cache/* /var/log/* /var/tmp/* /var/lib/dnf /var/lib/xkb
# greetd's /var state is declared in tmpfiles.d instead, so systemd recreates it
# per deployment rather than it being frozen into the first one.
rm -rf /var/lib/greetd

# /run and /tmp are runtime-only; content here trips bootc's nonempty-run-tmp
# lint. Remove only our own debris by name: /run/secrets and /run/systemd are
# bind mounts podman injects into the build container, not image content, and
# `rm -rf /run/*` fails on them with EBUSY and kills the build.
rm -rf /run/dnf /run/selinux-policy
find /tmp -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true

bootc container lint
