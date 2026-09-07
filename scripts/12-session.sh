#!/usr/bin/bash
# The graphical session: Hyprland, its portal, and the surrounding furniture.
#
# Hyprland is not in Fedora. It comes from the ashbuk COPR, which currently
# tracks upstream exactly. That is a third-party rebuild and therefore a real
# dependency -- a Fedora bump can strand it -- so the version is asserted below
# and a stale COPR fails the build rather than the boot.
#
# xdg-desktop-portal-hyprland is the reason this matters beyond tiling: it is
# the only portal offering an arbitrary-region share picker, which the GNOME
# session could not do.
set -euxo pipefail

### Expected versions -------------------------------------------------------
# Bump deliberately, having read the upstream release notes. A mismatch is a
# signal that the COPR moved under us, not something to paper over.
readonly WANT_HYPRLAND_MAJOR_MINOR="0.56"

dnf5 -y config-manager addrepo --from-repofile=https://copr.fedorainfracloud.org/coprs/ashbuk/Hyprland-Fedora/repo/fedora-44/ashbuk-Hyprland-Fedora-fedora-44.repo

dnf5 -y install --setopt=install_weak_deps=False \
    hyprland \
    xdg-desktop-portal-hyprland \
    xdg-desktop-portal-gtk

### Assert the compositor version -------------------------------------------
# The NVIDIA kernel lockstep taught this lesson before base-nvidia made it
# structural: a dependency that can silently drift should be checked at build
# time, loudly.
got="$(rpm -q --qf '%{version}' hyprland)"
case "${got}" in
    "${WANT_HYPRLAND_MAJOR_MINOR}".*)
        echo "OK: hyprland ${got} matches expected ${WANT_HYPRLAND_MAJOR_MINOR}.x"
        ;;
    *)
        echo "FATAL: hyprland version drifted." >&2
        echo "  expected: ${WANT_HYPRLAND_MAJOR_MINOR}.x" >&2
        echo "  got     : ${got}" >&2
        echo "Read the upstream release notes, then bump WANT_HYPRLAND_MAJOR_MINOR." >&2
        exit 1
        ;;
esac

### Session furniture -------------------------------------------------------
# All from Fedora proper. Notably this covers the hypr* pieces the COPR does
# not carry -- hyprlock, hypridle and hyprpaper have packaged sway equivalents,
# so no extra third-party dependency is taken on for them.
#
#   greetd + tuigreet   display manager; tuigreet is a console greeter, which
#                       suits a keyboard-driven session
#   swaylock            lockscreen. Deliberately NOT hand-rolled: a bug in an
#                       ext-session-lock-v1 implementation is a bypassable lock
#   swayidle/swaybg     idle handling and wallpaper
#   grim + slurp        screenshots, region selection
#   lxpolkit            polkit agent; the GNOME one is not packaged
#
# fuzzel and mako are deliberately ABSENT. The Quickshell shell provides the
# launcher and the notification server now, and mako must not merely be left
# out of autostart -- it ships
# /usr/share/dbus-1/services/fr.emersion.mako.service, so D-Bus starts it on
# demand the first time anything asks for org.freedesktop.Notifications. Only
# one process can own that name, so an installed-but-unstarted mako still wins
# the race sometimes and the shell then receives no notifications at all, with
# nothing logged anywhere. Removing the package removes the activation file.
dnf5 -y install --setopt=install_weak_deps=False \
    greetd \
    tuigreet \
    swaylock \
    swayidle \
    swaybg \
    grim \
    slurp \
    wlogout \
    lxpolkit \
    playerctl \
    brightnessctl

### Quickshell runtime ------------------------------------------------------
# The binary arrives from the builder stage; these are what it links against.
dnf5 -y install --setopt=install_weak_deps=False \
    qt6-qtbase \
    qt6-qtdeclarative \
    qt6-qtwayland \
    qt6-qtsvg \
    jemalloc

systemctl enable greetd.service
systemctl set-default graphical.target

dnf5 clean all
rm -rf /var/cache/libdnf5/* /var/lib/dnf/repos
