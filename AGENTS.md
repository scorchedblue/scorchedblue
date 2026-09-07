# ScorchedBlue — working agreements

What is true now. The reasoning, alternatives rejected, and decision history
live in the `scorched-planning` repository; this file states conclusions
without re-arguing them.

## Do not reopen

- **Terminal-first, and terminal-first means keyboard-first.** The terminal is
  the work surface; the Quickshell shell is the keyboard-navigable frame around
  it and it grows along that axis. Not GUI-less -- the shell is not being
  shrunk -- but nothing here is designed mouse-first.
- **Hyprland is the session**, with a Quickshell shell written in-house. Not
  GNOME, niri or KDE. Mutter implements no `wlr-layer-shell`, so a Quickshell
  bar has nothing to anchor to -- that is structural, and it is why the GNOME
  decision was reversed. See `scorched-planning` decisions/0002.
- **The base is pinned by digest, never a floating tag.** A base bump is an
  explicit, reviewable change to the `ARG`. That rule is not up for discussion;
  *which* base is, and has changed with the session each time.
  **Currently `base-nvidia`**, which is the only NVIDIA variant published --
  `base-nvidia-open`, `base-main-nvidia` and `base-main-nvidia-open` do not
  exist. The move off `base-main` plus in-house akmods was made to inherit the
  driver in lockstep with the kernel. It did **not** remove the kargs trap
  below: that expectation was wrong, and the file stays.
- **Do not vendor or fork another project's shell.** The point is our opinions,
  not inherited ones. The cost -- that it will not resemble the demos until real
  design work happens -- is accepted.
- **No hand-rolled lockscreen.** `ext-session-lock-v1` is security-sensitive and
  a bug there is a bypassable lock. `swaylock` covers it; the shell does not.
- **Rust owns everything that runs on a booted machine.** The `scorched` CLI,
  the theme engine, the helpers the shell spawns, and the libexec units. Not Go,
  not Python.
- **Build scripts stay bash.** `scripts/*.sh` run inside the Containerfile;
  porting them would mean compiling a binary during the build in order to run
  the build, and shell is the right language for "install packages, assert
  versions". This is the one deliberate exception to the rule above.
- **Never name another downstream image in this repository.** Not in code,
  comments, config, or anything shipped into the OS. Comparisons and "why we
  differ from X" reasoning belong in `scorched-planning`. Referring to the
  *base* (Universal Blue, `ublue-os`, `base-main`) is correct and expected
  -- that is what this is built on. Referring to a sibling product is not.

## Build rules

- **Verify every package against Fedora 44 before adding it.** Query the base
  image; do not assume. `starship` was assumed present and is not packaged at
  all.
- **Layers are additive.** A `rm` in a later `RUN` hides files without
  reclaiming space. Bind-mount large inputs (`RUN --mount=type=bind,from=…`)
  rather than `COPY`ing them, and clean caches in the layer that created them.
- **Never `rm -rf /run/*`.** podman bind-mounts `/run/secrets` and
  `/run/systemd` into the build container; removing them fails the build with
  `Device or resource busy`. Remove debris by name.
- **Vendored binaries are pinned by version and hash**, fetched from upstream
  releases. No `curl | bash`, no COPR for anything that could be a static
  binary.

## NVIDIA

- **The driver comes from the base. Never build or install akmods here.** The
  open kmod (`nvidia.ko` reports `Dual MIT/GPL`), the full userspace and the
  i686 packages are all inherited. A kernel module alone would give no
  `nvidia-smi`, no GL and no session; the i686 half is what 32-bit titles under
  Steam need for GL.
- **Kernel lockstep is now structural, not asserted.** One image, one kernel, so
  base and kmod cannot diverge the way they could when the akmods came from a
  second image. `just test` checks that `nvidia.ko` exists for the shipped
  kernel, which is all that remains of the old build-time assertion.
- **`base-nvidia` ships the OPEN kmod, and nothing on the surface says so.**
  The package is named `kmod-nvidia` whichever flavour is built, and its RPM
  `License` tag reads *NVIDIA License* even for the open modules; the image
  labels say nothing either. The single distinguishing fact is the module's own
  `MODULE_LICENSE`: `modinfo -k "$(rpm -q --qf '%{version}-%{release}.%{arch}'
  kernel-core)" -F license nvidia` prints `Dual MIT/GPL` for the open kmod and
  `NVIDIA` for the proprietary one. Measured against
  `base-nvidia@sha256:7adbf8d0…`: `Dual MIT/GPL`, `kmod-nvidia-610.57.04-1.fc44`.
  We are on the open modules deliberately, so `just test` asserts that string by
  name -- a base bump that swapped flavours would pass every other NVIDIA check
  here.
- **Keep `files/usr/lib/bootc/kargs.d/00-nvidia.toml`.** No RPM ships these
  kargs and **`base-nvidia` does not write them either** -- its
  `/usr/lib/bootc/kargs.d` is empty, byte-identical to `base-main`'s, and
  `ublue-os-nvidia-addons` ships repo files, a preset and a SELinux module and
  nothing that touches boot. The widespread belief that an NVIDIA base supplies
  them is the reason this bullet is worded this strongly. Without them nouveau
  claims the GPU from the initrd, `nvidia.ko` cannot attach, and the machine
  boots to a black screen with dead VTs: a perfectly valid image that cannot
  draw. Nothing fails at build time, which is why `just test` asserts each karg
  by name. Delete this file only against a listing of the base that shows it
  writing them.

## The session

- **Keep `files/usr/lib/systemd/user/hyprland-session.target`.**
  `xdg-desktop-portal.service` is `Requisite=graphical-session.target`, and that
  target is `RefuseManualStart=yes` -- reachable only as a dependency. GNOME got
  it from `gnome-session`; Hyprland starts no target at all. Without this unit
  every portal request fails with *"Could not activate remote peer
  `org.freedesktop.portal.Desktop`: startup job failed"*, which takes screen
  sharing with it -- the capability the whole pivot was for. Nothing logs an
  error until something asks for a portal, so the session looks perfectly
  healthy. It is started from the Hyprland config in `scorched-desktop`.
- **`uwsm` is not available.** Upstream expects it to do the job above, and the
  `hyprland` RPM ships `/usr/share/wayland-sessions/hyprland-uwsm.desktop`
  accordingly -- but `uwsm` is packaged neither in Fedora 44 nor in the Hyprland
  COPR this image builds from, so that session entry points at a binary nothing
  provides. Do not reach for it as the fix.
- **`mako` and `fuzzel` must stay out of the image.** The shell serves both
  notifications and the launcher now. mako is the dangerous one: it ships
  `/usr/share/dbus-1/services/fr.emersion.mako.service`, so leaving it installed
  but out of autostart is **not** enough -- D-Bus activates it on demand the
  first time anything asks for `org.freedesktop.Notifications`. Only one process
  can own that name, so the shell then receives nothing, and neither side logs a
  word about it. `just test` asserts both the package and the activation file
  are absent.
- **`hyprland-qtutils` is not available either**, from any enabled repository.
  It renders Hyprland's update-news and donation popups, which therefore fail.
  They are switched off in the Hyprland config rather than worked around here.

## Performance

- **This image is always in performance mode, by design.** ScorchedBlue targets
  desktops; there is no battery to preserve, so the kernel's default trade of
  latency for power is wrong on every machine it is meant for.
  `scorched-performance.service` sets it at boot.
- **Both knobs, not just the governor.** On `intel_pstate` in active mode the
  scaling governor is half the story: the hardware also takes an
  energy/performance hint, and leaving that at `balance_performance` holds
  clocks back even with the governor set to `performance`. A machine "set to
  performance" with EPP still balanced is the usual reason the change looks like
  it did nothing. Measured on this hardware: 16 policies, both knobs, powersave
  and balance_performance to performance and performance.
- **A karg cannot do this.** `cpufreq.default_governor=` sets the governor only
  and there is no kernel argument for the energy/performance preference, which
  is why this is a unit rather than an entry in `kargs.d`.

## Software placement

Two things earn a place in the **image**:

- **Work surface** — it defines ScorchedBlue as a terminal-first workstation.
  The terminal environment *is* the product; shipping it empty and making the
  user provision it contradicts the thesis. `rg`, `fd`, `bat`, `eza`, `xh`,
  `delta`, `gh`, `just`, `mise`, `starship`, and the terminal, shell,
  multiplexer and prompt that P2 adds.
- **Recoverability** — it must work before login, as root, or on a broken
  system. `neovim`, `chezmoi`, `git`, `delta`.

Then: GUI app → **Flatpak**. Drags a language runtime or heavy deps →
**container**. A personal addition on top of the work surface → **Homebrew**.
Language runtimes belong to **mise**.

**The admission test**, which is what stops the work-surface line swallowing
everything: *a single binary with no runtime stack behind it, either packaged by
Fedora or worth vendoring.* That is checkable. "I use it a lot" is not, and is
how an image tier stops meaning anything. `httpie` fails it — as an RPM it drags
python3-pip and python3-requests into `/usr` — which is exactly why `xh`
replaced it and is vendored.

**Homebrew is not the cheap tier, it is *your* tier.** The image ships what
ScorchedBlue is; Homebrew carries what a particular person adds. That is the
right split for an image other people install.

This supersedes an earlier rule that read "needs to work before login, as root,
or on a broken system → image" and nothing more. That rule never described the
actual list — `ripgrep` and `fd-find` were already in the image under it with no
justification offered — and it would have excluded the terminal environment,
which is the one thing this project is *for*.

Homebrew cannot be baked into the image: `/home` is a symlink to `var/home`, so
an installed brew lives in `/var`. The image ships the payload; the systemd unit
provisions it.

## ujust and tooling

**The drop-in must be named `60-custom.just`.** ujust does not read
`/usr/share/ublue-os/just/`; it runs a justfile composed at RPM install time
whose only extension point is `import? "/usr/share/ublue-os/just/60-custom.just"`.
The import is optional, so any other filename is ignored **without an error** and
the recipes just never appear. `just test` asserts they are reachable.

Recipes **orchestrate**; the `scorched` binary **works**. A recipe is a few
lines calling a subcommand; parsing, error handling and state belong in Rust
where they can be tested. Provisioning that needs root or must run unattended
belongs to a systemd unit, not a recipe.

## CI

`just ci` is what CI runs; keep them identical. `security` is **report-only** —
its findings are inherited from the base and cannot be fixed here.
`security-diff` is the gate that matters: it fails if our layers introduce a CVE
the base does not carry.

## Unattended sessions

Work may be picked up by an unattended agent from the issue queue. The landing
path is a pull request with auto-merge, never a push to `main`: the ruleset
forbids the latter, and a red `ci` must be able to stop a change.

**Never, at any authority level:**

- cosign keys, or anything in the signing path
- publishing to GHCR
- `bootc switch` / `rpm-ostree rebase` on the running machine
- adding a dependency that fails the vetting bar
- making `scorched-planning` public
- committing when `gitleaks` fires

Anything that cannot be settled alone becomes a `needs-decision` issue rather
than a guess. Report by commenting on the issue, not by committing a report.
