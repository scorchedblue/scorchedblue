#!/usr/bin/bash
# NVIDIA open kernel modules, from uBlue's prebuilt akmods cache.
#
# The GPU is an RTX 3060 (GA104, Ampere), comfortably past the Turing floor the
# open modules require, so akmods-nvidia-open is the supported path. There is no
# proprietary `akmods-nvidia` image -- only `-open` exists.
set -euxo pipefail

### Kernel lockstep assertion ------------------------------------------------
# The single sharpest failure mode in this build: if the base image bumps its
# kernel and the akmods image has not caught up (or vice versa), the result is a
# system with a kernel module that cannot load -- no driver, no session. That
# must fail loudly here, at build time, not quietly at boot.
#
# The kmod RPM filename embeds the kernel it was built against, e.g.
#   kmod-nvidia-7.1.13-200.fc44.x86_64-610.57.04-1.fc44.x86_64.rpm
base_kernel="$(rpm -q --qf '%{version}-%{release}.%{arch}' kernel-core)"
kmod_rpm="$(find /tmp/akmods/rpms/kmods -name 'kmod-nvidia-*.rpm' -print -quit)"

if [ -z "${kmod_rpm}" ]; then
    echo "FATAL: no kmod-nvidia RPM found in the akmods image" >&2
    exit 1
fi

case "$(basename "${kmod_rpm}")" in
    *"${base_kernel}"*)
        echo "OK: akmods kmod matches base kernel ${base_kernel}"
        ;;
    *)
        echo "FATAL: kernel mismatch." >&2
        echo "  base image kernel : ${base_kernel}" >&2
        echo "  akmods kmod       : $(basename "${kmod_rpm}")" >&2
        echo "Pin AKMODS_TAG to an image built against the base kernel." >&2
        exit 1
        ;;
esac

### Install ------------------------------------------------------------------
# One transaction so dependencies resolve together.
#
# rpms/nvidia/ carries the full userspace stack -- driver, libs, kmod-common,
# modprobe, persistenced, settings. Installing only the kmod (as an earlier
# draft of the plan did) yields a kernel module with no userspace: no nvidia-smi,
# no GL, no working session.
#
# The i686 packages in that directory are intentional: 32-bit games under Steam
# need 32-bit GL.
dnf5 -y install \
    /tmp/akmods/rpms/kmods/kmod-nvidia-*.rpm \
    /tmp/akmods/rpms/nvidia/*.rpm \
    /tmp/akmods/rpms/ublue-os/ublue-os-nvidia-addons-*.rpm

# Sanity: the module must exist for the kernel the image actually ships.
test -e "/usr/lib/modules/${base_kernel}/extra/nvidia/nvidia.ko.xz" ||
    test -e "/usr/lib/modules/${base_kernel}/extra/nvidia/nvidia.ko" ||
    {
        echo "FATAL: nvidia.ko not found under /usr/lib/modules/${base_kernel}" >&2
        exit 1
    }

dnf5 clean all
rm -rf /var/cache/libdnf5/* /var/lib/dnf/repos
