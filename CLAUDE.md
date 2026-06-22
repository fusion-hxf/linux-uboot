# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

Despite the `-uboot` directory name, this repo contains **no U-Boot source**. It is a
**Debian/Ubuntu root filesystem image builder** for the Xiaomi *raphael* device
(Redmi K20 Pro). The kernel, firmware, and `u-boot`/boot image are all pulled in as
prebuilt artifacts from external releases — this repo only assembles the rootfs and
wires up device-specific configuration.

Scripts and user-facing docs are written in **Chinese**; keep that language for log
messages and comments to match the existing style.

## Build commands

The build runs as a pipeline orchestrated by `build.sh`. It **must run as root**
(loop mounts, bind mounts, and `chroot`), and expects two prerequisites present in the
current working directory:

- `xiaomi-k20pro-boot.img` — the boot image
- `xiaomi-raphael-debs_<KERNEL_VERSION>/` — directory with `linux-image-`,
  `linux-headers-`, `firmware-xiaomi-raphael.deb`

Fetch those prerequisites first (not called by `build.sh`):

```bash
# scripts/00-download-deps.sh <KERNEL_VERSION> <GH_REPO>
bash scripts/00-download-deps.sh 7.0 GengWei1997/kernel-deb
```

Then build one image:

```bash
# build.sh <system-type> [kernel-version] [desktop-env]
# DEBIAN_VERSION or UBUNTU_VERSION must be set depending on system-type.
sudo BOOTSTRAP_TOOL=mmdebstrap DEBIAN_VERSION=trixie ./build.sh debian-phosh 7.0 phosh-core
sudo BOOTSTRAP_TOOL=mmdebstrap UBUNTU_VERSION=resolute ./build.sh ubuntu-server 7.0
```

- `system-type`: one of `debian-server`, `debian-gnome`, `debian-phosh`,
  `ubuntu-server`, `ubuntu-gnome`, `ubuntu-phosh` (see `SYSTEM_TYPES` in `config/build-config.sh`).
- `desktop-env`: only meaningful for `*-phosh` types — `phosh-core`, `phosh-full`, `phosh-phone`.
- `BOOTSTRAP_TOOL`: `mmdebstrap` (default) or `debootstrap`.

There is no test suite, linter, or unit-test harness. "Validation" is running the full
build and checking it completes; CI builds every matrix combination on real ARM runners.

Output: `rootfs.img` in the repo root (CI additionally produces `rootfs-*.7z` + `.sha256`).

## Architecture

### The numbered-script pipeline

`build.sh` sources `config/build-config.sh`, resolves config via `system_config` /
`sources_config`, exports a set of shared variables, then runs
`scripts/01-…` through `scripts/16-…` **in order**. State is shared three ways:

1. **Exported env vars** (`SYSTEM_TYPE`, `KERNEL_VERSION`, `DESKTOP_ENV`, `IMAGE_NAME`,
   `IMAGE_UUID`, `BOOT_IMG`, `KERNEL_DEBS_DIR`, distro version, etc.).
2. **The `rootdir/` loop mount** — every script reads/writes the image by touching
   `rootdir/...` directly or running `chroot rootdir <cmd>`.
3. Each script is independently `set -e` and re-derives its own defaults, so they can be
   run/debugged individually as long as `rootdir` is mounted and env vars are exported.

Pipeline phases (one concern per script):

| Script | Responsibility |
|---|---|
| `01-create-image` | `truncate` + `mkfs.ext4` the image, loop-mount as `rootdir` |
| `02-bootstrap` | `mmdebstrap`/`debootstrap` the base system, mount `boot.img` at `rootdir/boot` |
| `03-mount-dev` | bind-mount `/dev`, `/dev/pts`, `/proc`, `/sys` into `rootdir` |
| `04`–`05` | network + apt sources/update |
| `06-install-all-packages` | base + device + desktop packages, desktop autologin, ALSA, enable phosh |
| `07`–`08` | locale/timezone; screen commands + auto-blank service |
| `09-install-kernel` | `dpkg -i` the kernel/headers/firmware debs, `update-initramfs` |
| `10-config-ncm` | USB CDC-NCM gadget + dnsmasq |
| `11`–`14` | fstab, users, power/wifi, zram |
| `15`–`16` | cleanup; unmount everything, fsck, stamp fixed UUID |

### Configuration model

`config/build-config.sh` is the single source of per-system-type config via three shell
functions: `system_config` (image size, desktop flag, distro version defaults),
`sources_config` (mirror URLs), and `get_packages`.

**Gotcha:** `get_packages` in `config/build-config.sh` is largely *superseded* — the
authoritative package lists are hardcoded inline in `scripts/06-install-all-packages.sh`.
When changing what gets installed, edit `06`. Templates in `config/*.tpl` exist but the
scripts mostly inline their `cat > rootdir/...` heredocs rather than rendering the templates.

**Gotcha:** `blank_screen.service` is defined twice (in both `08-add-screen-commands.sh`
and `13-config-power.sh`); keep them in sync if you touch one.

## Device-specific invariants (do not change casually)

These must match what the bootloader / partition layout / kernel expect:

- **Fixed rootfs UUID** `ee8d3593-59b1-480e-a3b6-4fefb17ee7d8` (set in `16-finalize.sh`,
  also in `build.sh`). Boot cmdline uses `root=PARTLABEL=userdata`.
- **fstab** (`11-config-fstab.sh`): `/` ⇒ `PARTLABEL=userdata`, `/boot` ⇒ `PARTLABEL=cache`.
  Note the rootfs's `/boot` lives on the `cache` partition — consistent with the README
  flash steps (`fastboot flash cache xiaomi-k20pro-boot.img`, `fastboot flash boot u-boot.img`).
- **USB NCM networking** (`10-config-ncm.sh`): device IP `172.16.42.1`, dnsmasq DHCP
  `172.16.42.2-254`, configfs USB gadget. This is the primary "plug into a PC and SSH in" path.
- **Default credentials**: `user`/`1234` and `root`/`1234` (`12-create-users.sh`).
- **Qualcomm device packages**: `rmtfs`, `protection-domain-mapper`, `tqftpserv`.
- **WiFi**: `ath10k_core skip_otp=y` and NetworkManager `wifi.powersave = 2` (disabled) —
  fixes ping spikes (`13-config-power.sh`).
- **Custom shell commands**: `leijun` (blank screen) / `jinfan` (wake screen), added to
  `/etc/bash.bashrc`; `blank_screen.service` auto-blanks 15s after boot.

## External dependencies

Kernel/firmware debs and the boot image come from external GitHub releases, not this repo:

- Kernel debs: `GengWei1997/kernel-deb` (or override repo), release tag `kernel-v<version>`.
- `xiaomi-k20pro-boot.img`: `GengWei1997/kernel-deb` release `v1.0.0`.
- `alsa-xiaomi-raphael.deb`: only downloaded/installed for `phosh`/`gnome` desktop builds.

**Version default mismatch to be aware of:** `build.sh` defaults `KERNEL_VERSION` to `6.18`,
but the CI workflow and README default to `7.0`. Pass the version explicitly.

## CI

`.github/workflows/build-system.yml` is `workflow_dispatch` (manual, with a build matrix in
`parallel`/`single` mode) and also triggers on pushes/PRs touching `scripts/**`, `config/**`,
or `*.sh`. Builds run on `ubuntu-24.04-arm`, download the external artifacts in parallel, run
`build.sh`, then package `.7z` + `.sha256`. The `release` job publishes everything to a single
`latest` GitHub Release; images larger than 2 GB are left in Artifacts only.
