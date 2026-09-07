# ScorchedBlue

A keyboard-driven, terminal-first Fedora Atomic workstation, built as an OCI
image on top of Universal Blue.

The terminal is the work surface; Hyprland and an in-house Quickshell shell are
the keyboard-navigable frame around it. Terminal-first means keyboard-first, not
GUI-less. Everything custom is Rust, and everything visible agrees on one
palette.

**Not all of that is built yet.** What ships today is the session, the shell and
the driver stack. Ghostty, tmux, the Rust tooling and the theme engine are
sequenced in the roadmap and are called out below as direction, not as fact.

Not "bare-bones" -- NVIDIA drivers and a 32-bit gaming stack are gigabytes and
are not optional here. The goal is **opinionated and coherent**: nothing in the
image that was not chosen on purpose.

## What this is

| | |
| --- | --- |
| Base | `ghcr.io/ublue-os/base-nvidia`, pinned by digest |
| Session | Hyprland only, with a Quickshell shell written in-house |
| Terminal | Ghostty, built from source in the image; no fallback terminal is kept |
| Shell | bash, with starship |
| Graphics | NVIDIA open kernel modules, inherited from the base |
| Target | RTX 3060 (Ampere), single GPU |

## Design record

`AGENTS.md` (symlinked as `CLAUDE.md`) states the standing constraints for
working in this repository -- what is true now, without the argument.

The reasoning behind them, the alternatives rejected and on what grounds, and
the cross-repo roadmap live in the **`scorched-planning`** repository. Rationale
is recorded there and not repeated here, which is what keeps the two from
diverging.

## Related repositories

This is one of four projects, deliberately separated:

- **scorchedblue** (here) -- the image: base, packages, drivers, CI.
- **scorched-tools** -- Rust. Owns everything that runs on a booted machine:
  the `scorched` CLI, the theme engine, and the helpers the shell calls.
  `ujust` recipes orchestrate; these binaries do the work.
- **scorched-desktop** -- Hyprland configuration, the Quickshell shell, and
  chezmoi-managed dotfiles.
- **scorched-planning** (private) -- decisions, specs and the reasoning behind
  every constraint stated here.

## Usage

```
just build      # build the image locally
just test       # assertions against the built image
just lint       # shfmt + shellcheck
just security   # trivy, HIGH/CRITICAL, fixed only
just diff       # package delta against the base image
just vm         # bootable qcow2 for VM testing
just ci         # everything CI runs
```

Rebasing a machine onto it:

```
sudo bootc switch ghcr.io/scorchedblue/scorchedblue:latest
# recovery, if it boots badly:
sudo bootc rollback
```

## Software placement

Four layers, chosen by property rather than taste:

| Layer | Reachable by | Survives rollback |
| --- | --- | --- |
| Image (`/usr`) | root, systemd, pre-login, rescue shell | yes, atomically |
| Flatpak | your user, sandboxed | no |
| Container | inside the container | no |
| Homebrew (`/var`) | your user, unsandboxed | it is `/var`, so it is never rolled back |

**The rule.** Needs to work before login, as root, or on a broken system ->
image. GUI app -> Flatpak. Drags a language runtime or heavy deps -> container.
Otherwise -> Homebrew. Language runtimes themselves belong to `mise`.

Two things earn a place in the image:

- **Work surface** -- it defines ScorchedBlue as a terminal-first workstation.
  `ripgrep`, `fd-find`, `bat`, `eza`, `xh`, `git-delta`, `gh`, `just`, `mise`,
  `starship`. The terminal environment *is* the product here; shipping it empty
  and making you provision it would contradict the whole point.
- **Recoverability** -- it must work before login, as root, or on a broken
  system. `chezmoi` (it bootstraps everything else, so it cannot live in a
  user-space manager), `neovim` (`$EDITOR`, needed for `sudoedit` and for
  repairing a broken session), `git-delta` (the configured git pager -- absent,
  `sudo git` fails confusingly).

**The admission test** is what keeps the first line honest: a single binary with
no runtime stack behind it, either packaged by Fedora or worth vendoring. It is
checkable, where "I use it a lot" is not. `httpie` fails it and `xh` replaces
it.

`git` needs no entry -- `git-core` comes from the base and provides
`/usr/bin/git`. Nor do `jq`, `tree`, `lsof`, `ss`, `less`, `tar`, `zstd`,
`curl` or `rsync`, all of which the base already carries.

**Homebrew is not the cheap tier, it is yours.** The image ships what
ScorchedBlue is; Homebrew carries what you add on top.

## Things that will bite

**NVIDIA kernel arguments.** No RPM ships them -- and neither does the NVIDIA
base. `ghcr.io/ublue-os/base-nvidia` carries the driver, the userspace and the
i686 stack, but its `/usr/lib/bootc/kargs.d` is empty, identical to
`base-main`'s. `files/usr/lib/bootc/kargs.d/00-nvidia.toml` is therefore still
ours to maintain. Without it nouveau claims the GPU from the initrd,
`nvidia.ko` cannot attach, and the machine boots to a black screen with dead VTs.
Nothing fails at build time: the image is valid, it simply cannot draw. `just
test` asserts each karg by name, because this one has already cost a boot.

**Kernel lockstep** used to be the sharpest failure mode here, back when the
akmods came from a separate image that could drift from the base's kernel.
Taking the driver from the base makes it structural -- one image, one kernel --
so the build-time assertion is gone. `just test` still checks that `nvidia.ko`
exists for the kernel the image ships, which is what would fire if that ever
stopped being true.

**Portal arbitration.** `xdg-desktop-portal-hyprland` must win `ScreenCast`, or
arbitrary-region sharing -- the capability the GNOME session could not provide,
and the reason for the pivot -- is silently unreachable. The order is set in
`files/etc/xdg-desktop-portal/portals.conf` and asserted by `just test`. Losing
that arbitration would undo the pivot without any visible error.

**The Hyprland COPR.** Hyprland and its portal come from `ashbuk`, which
currently tracks upstream exactly. It is still a third-party rebuild and a
Fedora bump can strand it. `scripts/12-session.sh` asserts the compositor
version, so a stale COPR fails CI rather than a boot -- the same discipline as
the kernel lockstep. Bump the expected version deliberately, having read the
upstream release notes.

**Quickshell is pre-1.0.** It links private Qt APIs and must be rebuilt against
each Qt release or it crashes on ABI mismatch, which is why the builder stage
uses the same base as the final image. Expect the QML to need porting roughly
two or three times a year.

**CI disk space.** The image is ~10GB uncompressed and the base another ~7.5GB.
A stock GitHub runner does not have room, so `ci.yml` reclaims ~25GB of unused
preinstalled toolchains first. If that stops being enough, the options are a
larger runner or a self-hosted one -- not a smaller image, since the NVIDIA
stack alone is 2GB and is not optional.

## Homebrew

`/home` is a symlink to `var/home`, so an installed brew lives in `/var` --
deployment state, not the image's immutable `/usr`. **An image cannot contain an
installed Homebrew**; it can only ship the payload plus a mechanism to unpack
it. Hence the split:

| Concern | Owner |
| --- | --- |
| Payload (`/usr/share/homebrew.tar.zst`, 3.8MB) | image |
| First-boot provisioning | `scorched-brew-setup.service` (enabled) |
| provision-now / update / remove | `ujust scorched-brew*` |

ujust deliberately does *not* provision: that needs root to chown
`/home/linuxbrew` and must run unattended, and a user who does not know to run a
recipe would end up with no brew at all.

Two deliberate choices worth knowing:

- The owner is derived: first account with UID >= 1000, falling back to 1000
  only if none exists. A hardcoded UID is right on a single-user box and
  silently wrong otherwise.
- The payload is built from a **pinned, checksummed source tarball**
  (`6.0.21`, `79520db6...`) rather than Homebrew's `curl | bash` installer. An
  image build must not execute whatever a remote host serves that day.

**Verified behaviour of the small payload.** We ship a pristine brew (3.8MB
compressed, 26MB extracted) rather than a pre-warmed tree. It has
no `.git`, so until the first `brew update` the version string degrades to
`Homebrew >=4.3.0 (shallow or no git repository)`. The first `brew update`
bootstraps a full non-shallow clone (~138MB) and the version reports correctly
thereafter -- tested end to end, exit 0. Brew also downloads its vendored
portable-ruby on first use. Both costs land at first use rather than in every
image pull, which is the right trade for something that needs the network to be
useful anyway.

## Security scanning

`just security` reports HIGH/CRITICAL vulnerabilities. It is **report-only by
design**: the findings are inherited from the base image (chiefly `cosign`, via
`ublue-os-signing`), and we cannot fix them here. Failing CI on them would mean
a permanently red pipeline for something outside this repository's control.

`just security-diff` asks the question that *is* actionable -- did our layers
introduce a CVE the base did not already carry? -- and exits non-zero if so.

Two implementation notes worth knowing before editing those recipes:

- trivy cannot see rootless podman images without a socket. Rather than enable
  `podman.socket` permanently, the recipes start an ephemeral
  `podman system service` and point `DOCKER_HOST` at it. The socket lives in
  `XDG_RUNTIME_DIR` because unix socket paths cap at ~108 characters.
- `sysroot/ostree/repo` is skipped. It is the content-addressed object store, so
  scanning it re-reports every binary a second time under an unreadable hash.
- The two scans in `security-diff` run **sequentially**. trivy's cache is not
  safe for concurrent use and fails with "cache may be in use by another
  process".
