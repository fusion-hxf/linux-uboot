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
bash scripts/00-download-deps.sh 7.1 fusion-hxf/kernel-deb
```

Then build one image:

```bash
# build.sh <system-type> [kernel-version] [desktop-env]
# Defaults when omitted: ubuntu-server + kernel 7.1 + Ubuntu 26.04 (resolute).
# UBUNTU_VERSION/DEBIAN_VERSION default to resolute/trixie; override via env.
sudo BOOTSTRAP_TOOL=mmdebstrap ./build.sh                                    # ubuntu-server 7.1 resolute
sudo BOOTSTRAP_TOOL=mmdebstrap DEBIAN_VERSION=trixie ./build.sh debian-phosh 7.1 phosh-core
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
| `15`–`16` | cleanup + factory hardening (DNS/identity, see invariants); unmount, fsck, stamp UUID, convert raw → Android sparse image |

### Configuration model

`config/build-config.sh` is the single source of per-system-type config via three shell
functions: `system_config` (image size, desktop flag, distro version defaults),
`sources_config` (mirror URLs), and `get_packages`.

**Note:** package lists are hardcoded inline in `scripts/06-install-all-packages.sh` — edit `06` to
change what gets installed. (The old superseded `get_packages()` in `config/build-config.sh` and the
unused `config/*.tpl` templates have been removed; scripts inline their `cat > rootdir/...` heredocs.)

**Note:** `blank_screen.service` is defined once, in `08-add-screen-commands.sh` (the duplicate in
`13-config-power.sh` has been removed).

## Device-specific invariants (do not change casually)

These must match what the bootloader / partition layout / kernel expect:

- **Fixed rootfs UUID** `ee8d3593-59b1-480e-a3b6-4fefb17ee7d8` (stamped in `16-finalize.sh`,
  also in `build.sh`). **Load-bearing:** the external boot image's kernel cmdline is
  `root=UUID=ee8d3593…` (confirmed on-device `/proc/cmdline`: `… loglevel=3 splash
  root=UUID=ee8d3593-… rw`), so this UUID must match exactly or the device won't boot. (`fstab`
  separately uses `PARTLABEL=userdata` for `/`, `PARTLABEL=cache` for `/boot`.)
- **fstab** (`11-config-fstab.sh`): `/` ⇒ `PARTLABEL=userdata`, `/boot` ⇒ `PARTLABEL=cache`.
  Note the rootfs's `/boot` lives on the `cache` partition — consistent with the README
  flash steps (`fastboot flash cache xiaomi-k20pro-boot.img`, `fastboot flash boot u-boot.img`).
- **USB NCM networking** (`10-config-ncm.sh`): device IP `172.16.42.1`, dnsmasq DHCP
  `172.16.42.2-254`, configfs USB gadget. This is the primary "plug into a PC and SSH in" path.
- **Default credentials**: `user`/`1234` and `root`/`1234` (`12-create-users.sh`).
- **Qualcomm device packages**: `rmtfs`, `protection-domain-mapper`, `tqftpserv`.
- **WiFi**: `ath10k_core skip_otp=y` and NetworkManager `wifi.powersave = 2` (disabled) —
  fixes ping spikes (`13-config-power.sh`).
- **DNS stack** (`15-cleanup.sh`): consolidated onto **systemd-resolved**. `/etc/resolv.conf`
  → `/run/systemd/resolve/stub-resolv.conf` symlink; `FallbackDNS=223.5.5.5 119.29.29.29` for
  the USB-NCM-only case. `nss-tlsd`/`libnss-tls` is purged and the `tls` token stripped from
  `nsswitch.conf` hosts (its DoH upstreams are unreachable in CN and stall every `getaddrinfo`
  ~4s — see `dns-fix.md`). Build-time DNS (`04`) is `223.5.5.5`.
- **Per-device identity** (`15-cleanup.sh`): `/etc/machine-id` is emptied and SSH host keys are
  deleted at build time; both regenerate on first boot (`regenerate-ssh-host-keys.service`). Do
  NOT bake these in — `10-config-ncm.sh` uses `machine-id` as the USB serial, so a shared
  machine-id means colliding USB serials / DHCP DUIDs across devices.
- **usb0 is NOT NetworkManager-managed** (`13-config-power.sh`, `conf.d/10-unmanage-usb0.conf`);
  it is owned by `usb-ncm.service` + dnsmasq.
- **Boot-image sync hook** (`09-install-kernel.sh`): `/usr/local/sbin/sync-boot-images.sh` plus
  hooks in `etc/kernel/postinst.d` / `etc/initramfs/post-update.d` copy the newest
  `vmlinuz-*`/`initrd.img-*` onto the fixed names U-Boot loads (`/boot/linux.efi`,
  `/boot/initramfs`) on every kernel/initramfs update. `/boot` is vfat (no symlinks) so it COPIES;
  the 256 MB cache partition holds two sets. Without this, on-device updates are silent no-ops.
- **Custom kernel/firmware are `apt-mark hold`** (`09`) so apt / unattended-upgrades can't replace them.
- **Memory/storage tuning** (`14-config-zram.sh`): zram = zstd at `PERCENT=150` (adaptive to 6/8 GB
  variants, replaced a fixed 10 GB `SIZE`); `vm.swappiness=150`, `vm.page-cluster=0`; **earlyoom**
  enabled (chosen over systemd-oomd — needs only /proc, no PSI dep, though kernel has `CONFIG_PSI=y`);
  journald capped `SystemMaxUse=200M`; `fstrim.timer` enabled; fstab `/` uses `noatime`.
- **SSH config is a drop-in** (`12`, `sshd_config.d/10-raphael.conf`), not appended to the main file.
- **Do NOT delete `/lib/firmware/regulatory.db`** — `15-cleanup.sh` used to `rm -f /lib/firmware/reg*`,
  which broke cfg80211 regdomain (device dmesg: `failed to load regulatory.db`). That rm is removed
  and `wireless-regdb` is installed (`06`).
- **Hardware watchdog enabled** (`13`, `system.conf.d/10-watchdog.conf`, `RuntimeWatchdogSec=default`):
  `/dev/watchdog0` (`qcom_wdt`) is present on-device. `default` (not an explicit value) is deliberate — it
  opens+pings the device but leaves the timeout at the kernel/DT default (**30s** on sm8150), so it can never
  EINVAL. **Confirmed armed on-device** (boot journal: `Using hardware watchdog /dev/watchdog0: 'qcom_wdt'`
  + `Watchdog running with a hardware timeout of 30s`), so systemd auto-reboots a hung system. NOTE: in
  `default` mode `systemctl show -p RuntimeWatchdogUSec` reports `infinity` — that is the "don't change the
  timeout" sentinel, **NOT** off; judge armed/not via the boot journal lines above, not this property
  (the qcom_wdt sysfs node also omits `timeout`/`max_timeout`). `device-probe.sh` §9 keys off the journal.
- **Generic firmware backfill** (`09-install-kernel.sh`): the external `firmware-xiaomi-raphael.deb`
  ships device blobs but omits generic `linux-firmware` bits — device dmesg showed missing
  `qcom/a630_sqe.fw` (Adreno → GPU faults under a GUI) and `qca/crbtfw21.tlv` (Bluetooth → hci DOWN).
  The build now fetches these (+ `a640_gmu.bin`, `qcom/sm8150/a640_zap.mbn`, `qca/crnv21.bin`) from
  `linux-firmware` **only if absent** (never clobbers the deb's vendor/signed blobs); source override
  via `LINUX_FIRMWARE_BASE`. (`a630_gmu.bin` was removed — that's the sdm845 GMU; sm8150/Adreno 640
  needs `a640_gmu.bin`.) **GPU zap path**: the generic `a640_zap.mbn` lands at `qcom/sm8150/a640_zap.mbn`,
  but raphael's DTB sets `firmware-name = qcom/sm8150/{xiaomi,Xiaomi}/raphael/a640_zap.mbn` (the downstream
  kernel uses capital `Xiaomi`), so `09` also copies the generic zap to both device-specific paths (and
  into the initramfs hook). Without that copy the kernel logs `Unable to load …/a640_zap.mbn → gpu hw
  init failed -2`. If the generic (qcom-signed) zap is later rejected by TrustZone (`-22 initializing
  firmware`), extract the OEM-signed `a640_zap.mbn` from the device's MIUI `vendor` partition instead.
- **Custom shell commands**: `leijun` (blank screen) / `jinfan` (wake screen), added to
  `/etc/bash.bashrc`; `blank_screen.service` auto-blanks 15s after boot.

## Optimization roadmap

See `optimization-plan.md` for the full status analysis, the prioritized P0/P1/P2 roadmap, and
§七 (kernel-7.1 capability findings). P0 (DNS determinism, per-device identity, usb0 ownership) and
most of P1 (boot-image sync hook, apt-mark hold, earlyoom, zram/sysctl, noatime, journald cap,
fstrim, SSH drop-in) are implemented in `06/09/11/12/13/14/15`. Watchdog self-healing is **confirmed
armed on-device** (30s, see invariants). Deferred pending on-device confirmation (run `device-probe.sh`
at repo root): IPv6 re-enable layer, suspend quality.

## External dependencies

Kernel/firmware debs and the boot image come from external GitHub releases, not this repo:

- Kernel debs: `fusion-hxf/kernel-deb` (or override repo), release tag `kernel-v<version>`.
- `xiaomi-k20pro-boot.img`: `fusion-hxf/kernel-deb` release `v1.0.0`.
- `alsa-xiaomi-raphael.deb`: only downloaded/installed for `phosh`/`gnome` desktop builds.

**Defaults:** kernel version defaults to `7.1` everywhere (`build.sh`, `00-download-deps.sh`, CI). The
CI's default `system_types` is the Ubuntu set (`ubuntu-server,ubuntu-gnome,ubuntu-phosh`) and
`ubuntu_versions=resolute` (26.04). `build.sh` with no args builds `ubuntu-server`. Pass other values
explicitly to build Debian or kernel 6.18/7.0.

## CI

`.github/workflows/build-system.yml` is **`workflow_dispatch` only** (manual; the push/PR
auto-triggers were removed). With defaults it builds a single `ubuntu-server` + kernel `7.1` +
`resolute` image (the matrix generator also has `${VAR:-default}` fallbacks so empty inputs still
produce that one image). `KERNEL_REPO` falls back to `fusion-hxf/kernel-deb`. Builds run on
`ubuntu-24.04-arm`, download the external artifacts in parallel, run `build.sh`, then package
`.7z` + `.sha256`. The `release` job publishes to a single `latest` GitHub Release; images larger
than 2 GB are left in Artifacts only.
