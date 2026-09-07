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
    bat \
    eza \
    yq

### git is already here ------------------------------------------------------
# Not listed above because `git-core` comes from the base and provides
# /usr/bin/git. The full `git` package adds gitk, git-email and the perl
# tooling, none of which this image has a use for. `just test` asserts the
# binary rather than a package name, so this stays correct either way.

### Why this list is what it is ----------------------------------------------
# Two things earn a place in the image, and the list above is both of them
# mixed together:
#
#   WORK SURFACE   -- it defines ScorchedBlue as a terminal-first workstation.
#                     rg, fd, bat, eza, delta, gh, just (and mise, xh, starship,
#                     vendored in the Containerfile). The terminal environment
#                     IS the product here; shipping it empty and making the user
#                     provision it contradicts the whole point.
#   RECOVERABILITY -- it must work before login, as root, or on a broken
#                     system. neovim, chezmoi, git, delta.
#
# delta appears in both, which is fine: the pager makes `sudo git` behave, and
# it is also what reading a diff should look like here.
#
# THE ADMISSION TEST, which is what keeps the first line from swallowing
# everything: a single binary with no runtime stack behind it, either packaged
# by Fedora or worth vendoring. That is checkable. "I use it a lot" is not, and
# is how an image tier stops meaning anything.
#
### yq is the Go one -------------------------------------------------------
# Fedora's `yq` is mikefarah/yq: a single static Go binary, 5MiB, no
# dependencies. Worth stating because there is a second, unrelated project of
# the same name -- kislyuk/yq -- which is a Python wrapper around jq. That one
# would drag a runtime stack into /usr and fails the admission test outright.
# If `yq --version` ever stops reporting mikefarah's, something has been
# swapped underneath us.

### Already in the base: do NOT add these -----------------------------------
# The base image already provides:
#
#   git (via git-core)  just  jq  ss  tree  lsof  less  tar  zstd
#   curl  rsync  vim  wget
#
# `vim` is vim-enhanced, not the minimal build, so it is a real vim and not
# just a `vi` stub. neovim is still installed alongside it as $EDITOR.
#
# `wget` is provided by wget2-wget: the command exists, but it is GNU Wget2,
# not classic wget. Behaviour differs in places (notably --mirror and some
# retry semantics), so a script written against wget 1.x should be checked
# rather than assumed to work.
#
# `just` is the surprising one and worth stating plainly: uBlue's `ujust` is a
# just wrapper, so the base carries just-1.57.0 -- which is exactly the version
# mise pins for these repositories. The image and a checkout therefore agree by
# construction, and adding `just` to the list above would be a no-op.
#
# Worth stating because several are things a checklist would otherwise reach
# for. Adding them explicitly is a no-op that makes the delta look larger than
# it is, and `just diff` exists to show what this image actually adds.

### Homebrew: yours, not the product's --------------------------------------
# zoxide, tealdeer and the rest of the personal long tail belong to the
# Homebrew tier, provisioned by scorched-brew-setup.service and installed from
# a Brewfile that scorched-desktop manages via chezmoi.
#
# The split is not "cheap tier / expensive tier". It is: the image ships what
# ScorchedBlue *is*, and Homebrew carries what a particular person adds on top.
# That is the right line for an image other people install.
#
# It is also where anything failing the admission test goes. `httpie` is the
# example worth keeping: as an RPM it drags python3-pip, python3-pygments and
# python3-requests into /usr, which is a runtime stack, so it cannot be part of
# the work surface however much someone likes it. `xh` replaced it and is a
# single static musl binary, which is precisely why xh is vendored above and
# httpie is not here.

# Clean in this layer: a later `rm` would hide the cache without reclaiming it.
dnf5 clean all
rm -rf /var/cache/libdnf5/* /var/lib/dnf/repos
