# shellcheck shell=bash
# ScorchedBlue -- default bash prompt.
#
# starship is in the image (see Containerfile) but wires nothing up on its
# own -- without a `starship init` call in a shell startup file, every
# session runs bash's compiled-in PS1. /etc/profile.d/*.sh is Fedora's own
# extension point for this, sourced by both /etc/profile (login shells) and
# /etc/bashrc (interactive non-login shells), so this fires either way with
# no edit to either file.
#
# starship itself only ever reads $STARSHIP_CONFIG or ~/.config/starship.toml
# -- it has no system config path the way tmux does. STARSHIP_CONFIG is set
# to the ScorchedBlue default here, but only when neither of those is already
# in play, so a user's own choice -- env var or file -- still wins.
[ -n "$BASH_VERSION" ] || return 0
[[ $- == *i* ]] || return 0
command -v starship >/dev/null 2>&1 || return 0

user_config="${XDG_CONFIG_HOME:-$HOME/.config}/starship.toml"
if [ -z "$STARSHIP_CONFIG" ] && [ ! -f "$user_config" ]; then
    export STARSHIP_CONFIG=/etc/starship.toml
fi
unset user_config

eval "$(starship init bash)"
