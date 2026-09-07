#!/usr/bin/bash
# Package add/remove sets.
#
# Every name here was verified present in Fedora 44 by querying the base image
# directly (podman run <base> dnf5 repoquery). Do not add a name without doing
# the same -- `starship` was assumed available during planning and is not
# packaged at all, which is why it is vendored in the Containerfile instead.
set -euxo pipefail

### Remove ----------------------------------------------------------------
# Nothing. base-main ships no desktop environment, so there is no application
# payload to strip -- the reason the base moved here from silverblue-main.
# Streamlining is additive again rather than subtractive, which also retires
# the concern about removals re-applying on every base bump.

### Add: image tier ---------------------------------------------------------
# These earn a place in /usr because they must work before login, as root, or
# on a system that is already broken. See the placement policy in the plan.
#
#   chezmoi     bootstrap paradox: it lays down the dotfiles that configure
#               everything else, so it cannot live in a user-space manager
#   neovim      $EDITOR; needed for sudoedit and for repairing a box whose
#               graphical session will not start
#   git-delta   the configured git pager -- if gitconfig names it and it is
#               missing from root's environment, `sudo git` fails confusingly
#   ripgrep     small, constant use, genuinely wanted in a rescue shell
#   fd-find     same
#   fastfetch   answers "which image am I on" -- image ref, digest, kernel and
#               which GPU driver actually bound. That is a rescue-shell
#               question, asked before login on a machine already
#               misbehaving, and Homebrew is not provisioned then. It reads
#               the deployment through rpm-ostree rather than bootc, because
#               `bootc status` demands root in every output format. ~2MB
#               including its single dependency, yyjson.
#
#   wl-clipboard  neovim's clipboard bridge on Wayland. A weak dependency of
#                 neovim, so it must be named explicitly now that weak deps are
#                 off, or yanking to the system clipboard silently stops working
#   inotify-tools neovim file watching; 0.2MB, also a weak dependency
#
# Already present in the base, deliberately not re-listed: tmux, fzf, jq,
# lsof, tree, iproute (provides ss), git.
#
# --setopt=install_weak_deps=False is the important flag here. Without it
# `neovim` Recommends `tree-sitter-cli`, which drags in nodejs22, gcc, make,
# binutils, glibc-devel and kernel-headers -- 337MB of language runtime and C
# toolchain, in a runtime OS image, arriving unasked. That is exactly what the
# placement policy sends to mise instead.
#
# The cost is real and deliberate: `:TSInstall` in neovim will fail, because
# nvim-treesitter compiles grammars with cc and node. Install those through mise
# when you need them.
#
# It also drops `xsel`, an X11 clipboard tool of no use on a Wayland-only
# session.
dnf5 -y install --setopt=install_weak_deps=False \
    chezmoi \
    neovim \
    git-delta \
    ripgrep \
    fd-find \
    fastfetch \
    wl-clipboard \
    inotify-tools \
    gh \
    just

### git is already here ------------------------------------------------------
# Not listed above because `git-core` comes from the base and provides
# /usr/bin/git. The full `git` package adds gitk, git-email and the perl
# tooling, none of which this image has a use for. `just test` asserts the
# binary rather than a package name, so this stays correct either way.

### Why gh and just are in the image ----------------------------------------
# They fail the "works before login, as root, or on a broken system" test that
# governs the rest of this list, so they are here on a second, narrower
# argument: this is a terminal-first workstation whose own tooling is driven by
# `just`, and whose repositories are driven by `gh`. A machine that cannot run
# `just ci` until Homebrew has finished provisioning cannot repair itself, and
# first-boot provisioning is exactly when a machine is most likely to need it.
#
# Both are single static-ish binaries packaged by Fedora, with no runtime stack
# behind them -- the property that keeps httpie out, below, does not apply.
# just-1.57.0 also matches the version mise pins for the repositories, so the
# image and a checkout agree by construction.

### Leaf tools: NOT here --------------------------------------------------
# httpie, zoxide, bat, tealdeer and the rest of the interactive long tail
# belong to the Homebrew tier, provisioned by scorched-brew-setup.service and
# installed from a Brewfile that scorched-desktop manages via chezmoi.
#
# Keeping them out of the image is not just tidiness: `httpie` as an RPM drags
# python3-pip, python3-pygments and python3-requests into /usr, which is exactly
# the "heavy dependency stack" the placement policy sends elsewhere. Homebrew's
# build is self-contained.

# Clean in this layer: a later `rm` would hide the cache without reclaiming it.
dnf5 clean all
rm -rf /var/cache/libdnf5/* /var/lib/dnf/repos
