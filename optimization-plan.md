# 小米 Raphael (Redmi K20 Pro) Linux 系统 — 现状分析与优化计划

> 文档日期：2026-06-23
> 目标设备：Xiaomi raphael / Redmi K20 Pro（Qualcomm sm8150）
> 目标系统：Ubuntu 26.04（resolute）+ mainline 内核 7.1
> 长期目标：从「能启动」演进为「稳定、可用的生产级」系统

---

## 一、项目本质

本仓库**不含 U-Boot / 内核源码**，是一个 **Debian/Ubuntu rootfs 镜像装配器**。内核、固件、boot 镜像都是外部 GitHub Release 的预编译产物；仓库只负责把 rootfs 拼出来并写设备相关配置。

构建是 `build.sh` 编排的串行管线 `scripts/01 → 16`，必须 root 运行（loop/bind mount + chroot）。状态通过三处共享：导出的环境变量、`rootdir/` 这个 loop 挂载点、各脚本各自 `set -e` 重新推导默认值。

---

## 二、现状分析

### 2.1 构建管线（一句话职责）

| 脚本 | 职责 |
|---|---|
| 01 | truncate + mkfs.ext4，loop 挂载为 `rootdir` |
| 02 | mmdebstrap/debootstrap 基础系统，挂载 boot.img 到 `rootdir/boot` |
| 03 | bind mount `/dev /dev/pts /proc /sys` |
| 04–05 | 网络/主机名 + apt 源/update |
| 06 | 基础包 + 设备包 + 桌面包；桌面自动登录；启用 phosh |
| 07–08 | locale/时区；熄屏命令 + 自动熄屏服务 |
| 09 | dpkg -i 内核/headers/firmware；update-initramfs |
| 10 | USB CDC-NCM gadget + dnsmasq |
| 11–14 | fstab、用户、电源/WiFi、zram |
| 15–16 | 清理；卸载、fsck、固化 UUID |

### 2.2 分区方案

- `userdata` ← `rootfs.img`（ext4，固定 UUID，首启 `x-systemd.growfs` 撑满分区）
- `cache` ← `xiaomi-k20pro-boot.img`，运行期挂 `/boot`（vfat，存 `linux.efi` + `initramfs`）
- `boot` ← `u-boot.img`
- cmdline：`root=PARTLABEL=userdata`；无独立 swap（用 zram）；`errors=remount-ro` 已设

**问题：**
- **P1** `/` 缺 `noatime`，无明确 TRIM 策略 → 闪存写放大与长期寿命/性能。
- **P2** fstab 中 `/boot` 也是 `pass=1`（常规应 `/`=1、其他=2），不规范。
- 固定 rootfs UUID 全设备相同：运行期靠 PARTLABEL，无害，属历史遗留。

### 2.3 启动流程

链路：`u-boot.img`（boot 分区）→ 从 cache 分区（/boot, vfat）加载固定名 `linux.efi` + `initramfs` → cmdline `root=PARTLABEL=userdata` → ext4 rootfs。`15-cleanup.sh` 把 `vmlinuz-*`→`linux.efi`、`initrd.img-*`→`initramfs`。

**问题：**
- **P1（真隐患）内核/initramfs 更新一致性断裂**：U-Boot 只认固定名 `linux.efi`/`initramfs`，但设备上任何触发 `update-initramfs` 的操作（apt 升级、固件/headers 改动等）只会生成 `initrd.img-<ver>`，**不会**自动改名 → U-Boot 继续加载旧 initramfs，新 initramfs 静默不生效。应做成机制（kernel postinst.d hook 或 systemd path 单元自动同步），而非构建期一次性改名。
- cmdline 由外部 u-boot/boot 持有，本仓库改不到 → IPv6 若在 cmdline 关闭，只能用 sysctl 兜底或写文档。
- **P2** 启动无 `quiet`/splash，控制台啰嗦（调试期是好事，打磨期可选收敛）。

### 2.4 系统组件

**网络 / DNS**
- **P0** `04` 把 `/etc/resolv.conf` 硬编码为 `nameserver 1.1.1.1`（国内被干扰），且全程没改回 resolved stub 软链 → 出厂镜像带这个死文件，是否被覆盖取决于运行期组件、**非确定**；纯 USB-NCM 场景 DNS 直接坏。
- **P0** `dns-fix.md` 的 `tls`/`nss-tlsd` 问题**没进构建脚本**（grep 已确认）→ 重新构建必复发。
- dnsmasq 用 `port=0` 只做 DHCP、避开 :53，与 resolved 不冲突 —— 这点设计是对的。
- **P0** NM 可能接管 usb0，与手设 static + dnsmasq 服务端打架 → 需标 usb0 为 NM 非托管。

**设备身份唯一性**
- **P0** `/etc/machine-id` 未清空，而 `10-config-ncm.sh` 用它当 USB 序列号 → 全设备序列号相同；并影响 DHCP DUID / journald / dbus。
- **P0** SSH host key 在 `06` 装 openssh 时即生成并烤进镜像 → 全网设备共用同一套主机密钥（安全失效）。

**安全基线**
- 默认 `root/1234`、`user/1234`，`PermitRootLogin yes` + `PasswordAuthentication yes`。
- **P1** `12` 把 sshd 设置**追加**到 `sshd_config` 末尾；sshd「首条匹配生效」，一旦有更靠前的同名项会被无声覆盖 → 应改 `/etc/ssh/sshd_config.d/*.conf` drop-in。生产版应首启强制改密或文档明示。

**内存 / 存储稳定性**
- **P1** `14` 设 `SIZE=10240`（=10GB zram）在 6/8GB 机上偏激进；且无 OOM 兜底（systemd-oomd/earlyoom）→ 压力下易硬卡死而非优雅杀进程。需复核 zram 大小、加 oomd、调 `vm.swappiness`。
- **P1** journald 无容量上限 → 闪存写放大、可能写满小 rootfs。

**更新安全**
- **P1** 定制内核/固件是 `dpkg -i` 装的，未 `apt-mark hold` → 有被同名包/unattended-upgrades 误替换的风险。

**构建质量 / 技术债**
- **P2** `blank_screen.service` 在 `08`、`13` 各定义一次；`get_packages` 已被 `06` 内联取代；`config/*.tpl` 基本未用。
- **P2** `15-cleanup.sh` 删 `/lib/firmware/reg*`（含 `regulatory.db`）→ 可能限制 WiFi 监管域/5G 信道/发射功率，需确认是否有意。

---

## 三、根因洞察：构建期非确定性

`dns-fix.md` 暴露的不是单点 bug，而是**一类问题**：本该「每台设备首启生成」或「由运行期组件接管」的状态，被构建期错误地固化成了一个静态错误值。

| 本应运行期决定 | 现在被构建期错误固化成 | 后果 |
|---|---|---|
| `/etc/resolv.conf` | 静态 `1.1.1.1` | 国内 DNS 被干扰；USB-only 直接坏 |
| `nsswitch` hosts 行 | 带 `tls`（重构必复现） | getaddrinfo 必现 ~4s 超时 |
| `/etc/machine-id` | 构建主机的值 | 全设备 USB 序列号/DUID 撞车 |
| SSH host keys | 构建期生成 | 全设备同密钥，安全失效 |
| initramfs 名字 | 一次性改名，非机制 | 设备更新后静默不生效 |

**统一原则：** 凡「每设备应唯一」或「应由运行期组件接管」的状态，构建末尾要么清空交首启重生成，要么收口到一个确定组件（DNS → systemd-resolved）。

---

## 四、优化路线图

### P0 — 稳定性/可用性硬伤，且与 dns-fix 同类（本次实施）

1. **DNS 栈确定化**：移除/屏蔽 `nss-tlsd`/`libnss-tls` + 防御性修 nsswitch；`resolv.conf` 收口到 systemd-resolved stub；`FallbackDNS=223.5.5.5 119.29.29.29`。
2. **设备身份唯一化**：清空 `machine-id`、修 dbus 软链；删 SSH host key + 首启自动重生成服务。
3. **usb0 交给自己**：NM 标 `unmanaged-devices=interface-name:usb0`。
4. **构建期临时 DNS** 改 `223.5.5.5`（国内本地构建友好）。

### P1 — 生产健壮性

5. ✅ **内核/initramfs 更新一致性**（`09`）：`/usr/local/sbin/sync-boot-images.sh` + `kernel/postinst.d`、`initramfs/post-update.d` 两钩子，设备端更新后自动把最新 `vmlinuz`/`initrd.img` 复制成固定名 `linux.efi`/`initramfs`（/boot=256MB 容得下两套）。
6. ✅ **SSH 改 drop-in**（`12`）：写 `sshd_config.d/10-raphael.conf`，不再追加主配置末尾。（首启强制改密属安全策略，暂缓以免误锁。）
7. ✅ **内存兜底**（`06`+`14`）：装并启用 **earlyoom**（仅依赖 /proc，不要求 PSI）；zram 改 `PERCENT=150` 自适应（取代写死 10GB）；`vm.swappiness=150`、`vm.page-cluster=0`。
8. ✅ **存储寿命**（`11`+`14`）：`/` 加 `noatime`；启用 `fstrim.timer`；journald `SystemMaxUse=200M`。
9. ✅ **锁定定制内核/固件**（`09`）：`apt-mark hold`（包名从 deb 的 Package 字段动态取）。
10. ⏸ **IPv6 策略决策**：内核 `CONFIG_IPV6=y`，故关闭在运行期 → 待 `device-probe.sh` 定位层级后处理。

### P2 — 打磨 / 技术债

11. 合并重复（`blank_screen.service` 08/13、`get_packages` vs 06、清理/启用模板）。
12. 复核 `15` 删 `regulatory.db` 对 WiFi 的影响。
13. USB gadget 健壮性（UDC 就绪竞态），可选加 RNDIS 兼容 Windows 免装驱动。
14. 构建可靠性：apt/curl 重试，`set -u`/`pipefail`。
15. ⏸ **watchdog 自愈**（`RuntimeWatchdogSec`）：内核已含 `QCOM_WDT` 驱动 → 待 `device-probe.sh` 确认 `/dev/watchdog` 存在即可启用。
16. 🔍 **ramoops/pstore 崩溃日志**：内核 `CONFIG_PSTORE_RAM=y` 已开 → 可保存重启前的内核日志用于生产排障（需保留内存区，属外部 boot/内核侧）。

---

## 五、P0 本次实施明细

| 改动 | 落点 | 内容 |
|---|---|---|
| 构建期 DNS | `04-config-network.sh` | `NAMESERVER` 默认 `1.1.1.1` → `223.5.5.5` |
| 安装 resolved | `06-install-all-packages.sh` | 显式 `apt-get install -y systemd-resolved` |
| usb0 非托管 | `13-config-power.sh` | 写 `conf.d/10-unmanage-usb0.conf` |
| DNS 确定化 | `15-cleanup.sh` | purge nss-tlsd/libnss-tls；sed 清 nsswitch 的 `tls`；enable systemd-resolved；`resolved.conf.d/fallback.conf`；`resolv.conf` → stub 软链 |
| 身份唯一化 | `15-cleanup.sh` | 清空 `machine-id` + dbus 软链；删 `ssh_host_*`；装并启用 `regenerate-ssh-host-keys.service` |

**DNS 方案选择说明：** 采用 systemd-resolved 收口（Ubuntu 原生设计，当前被 `04` 的静态文件意外破坏）。`resolv.conf` → `/run/systemd/resolve/stub-resolv.conf`；nsswitch `dns` 走 glibc → stub → resolved；`FallbackDNS` 保证无 DHCP DNS（纯 USB-NCM）时仍可解析。若日后想回退到「静态 223.5.5.5」简单方案：在 `15` 去掉 resolved 相关步骤、把 `resolv.conf` 写成普通文件即可。

---

## 六、待设备侧确认（运行 `device-probe.sh` 一键采集）

仓库根的 `device-probe.sh` 是一份**只读综合诊断**：在已启动设备上 `sudo bash device-probe.sh`，
一次跑完 12 类检测并给出"判定（OK/WARN/ISSUE）+ 建议 + 能力矩阵"，结果存成 `raphael-report-<时间>.txt`。
把该报告贴回即可对症收尾。它覆盖以下构建期无法判定的运行期能力：

1. **IPv6 在哪层被关**（内核 `CONFIG_IPV6=y`，必是 sysctl/cmdline 层）→ 决定 P1#10。
2. **`/dev/watchdog` 是否存在**（内核含 `QCOM_WDT`）→ 决定 P2#15 能否启用 `RuntimeWatchdogSec`。
3. **TRIM/discard 是否生效**（`lsblk -D` 的 DISC-MAX）+ `fstrim -v /` 实测。
4. **suspend 质量**（`/sys/power/mem_sleep` 是 `[s2idle]` 还是 `deep`）。
5. **P0 验证**：resolv.conf 软链、resolved 状态、nsswitch hosts、是否残留 nss-tls。
6. **zram/内存实况**：`zramctl`、`free -h`、`swapon --show`。

## 七、机型能力调研结论（kernel 7.1：`config-7.1.0-sm8150-...`）

解包 `linux-image-xiaomi-raphael.deb`（k7.1）核对内核 config，确认每个优化项是否被该机型支持：

| 能力 | 内核 config | 结论 / 采用 |
|---|---|---|
| zram + zstd | `ZRAM=m`, `ZRAM_BACKEND_ZSTD=y`, `DEF_COMP="zstd"` | ✅ → zstd + PERCENT=150 |
| PSI | `CONFIG_PSI=y` | ✅ oomd 亦可；仍选 earlyoom（依赖更少、更稳） |
| UFS / TRIM | `SCSI_UFSHCD=y` | ✅ → 启用 `fstrim.timer`（实效待 `lsblk -D` 确认） |
| watchdog | `WATCHDOG=y`, `QCOM_WDT=m`, `HANDLE_BOOT_ENABLED=y` | ⏸ 驱动在 → 待确认 `/dev/watchdog` 再开自愈 |
| IPv6 | `CONFIG_IPV6=y` | ⏸ 编进内核 → 关闭在运行期，待定位 |
| suspend | `SUSPEND=y`, `PM_SLEEP=y` | ✅ 内核支持；质量（s2idle/deep）待实测 |
| pstore/ramoops | `PSTORE_RAM=y`, `PSTORE_CONSOLE=y` | 🔍 可做生产崩溃日志（需保留内存区，外部侧） |
| /boot 容量 | cache 分区 = 256MB | ✅ 容两套 kernel+initramfs → 同步钩子用复制安全 |

## 八、设备报告分析结论（raphael-report-20260623-083100，仅手动 DNS 修复的旧镜像）

实测设备：6GB K20 Pro，Ubuntu 26.04，内核 7.1，桌面是 **KDE Plasma**（不在本仓库 phosh/gnome 矩阵内）。
remoteproc(modem/cdsp/adsp)、rmtfs/pd-mapper/tqftpserv、WiFi、触摸(Goodix)、显示(msm_dpu)、NCM、TRIM、IPv6 均正常；启动 28s、温度凉爽、电池正常。

### 新发现的真实 Bug
1. ❌→✅ **regulatory.db 被本仓库自删**：`15-cleanup.sh` 的 `rm -f /lib/firmware/reg*` 删掉了 regulatory.db（dmesg `failed to load regulatory.db`），限制 WiFi 监管域。**已移除该 rm + 装 wireless-regdb**。
2. ⚠️ **Adreno GPU 固件缺失**：dmesg `qcom/a630_sqe.fw failed -2` → GPU 故障（日志 `adreno gpu fault`/`dpu hangcheck recover`，offending=plasmashell）。属外部 `firmware-xiaomi-raphael.deb` 缺文件，**待决策**。
3. ⚠️ **蓝牙固件缺失**：`qca/crbtfw21.tlv failed -2` → hci0 DOWN。同属外部固件 deb，**待决策**。
4. ⚠️ **smartmontools.service failed → 系统 degraded**：手机无 SMART，无意义。建议在 Plasma 定制里 `systemctl mask smartmontools`（不在本仓库矩阵内，未改脚本）。

### 计划项的"实锤"验证
- ✅ **SSH host key = `root@runnervmju8gg`**（GitHub CI runner 生成，全设备相同）→ P0 身份修复确属必需。
- ✅ machine-id 固化；resolv.conf 为 `foreign` 静态文件直指 223.5.5.5、绕过 resolved → P0 收口确属必需。
- ✅ **无 OOM 守护**（PSI=yes）→ P1 earlyoom 必需。
- ✅ zram=10G、swappiness=60（5.3GB RAM 上偏大）→ P1 PERCENT=150 改进。
- ✅ / 为 relatime → P1 noatime 改进。
- ✅→**本轮已实现**：`/dev/watchdog` 存在 → 启用 `RuntimeWatchdogSec=60s`。
- ✅ **IPv6 已启用**（3 个全局地址，sysctl/cmdline 均未关）→ P1#10 关闭，无需动作。
- ✅ TRIM(DISC-MAX=32G)+fstrim.timer 已 active；DNS 延迟已正常（getent 0.13~0.23s）。

### 重要更正
- 启动 cmdline 实为 `root=UUID=ee8d3593-…`（**非** `PARTLABEL=userdata`）→ 固定 UUID 是**承重项**，必须与外部 boot.img 一致，已更正 CLAUDE.md。

### 固件缺口修复（已选方案 B：本仓库定向抓取，见 `09-install-kernel.sh`）
构建期从官方 linux-firmware 补齐固件 deb 缺失的【通用】文件，**仅在缺失时下载、绝不覆盖厂商 blob**：
- ✅ `qcom/a630_sqe.fw`(34K) + `qcom/a630_gmu.bin`(33K)：Adreno 通用微码（确认缺失 → 修 GPU 故障）
- ✅ `qca/crbtfw21.tlv`(173K)：QCA 蓝牙固件（确认缺失 → 修 BT 不起）
- 🔬 `qcom/sm8150/a640_zap.mbn`(14K)：GPU zap shader（best-effort：linux-firmware 的 sm8150 版；若 raphael TZ 拒绝其签名，需从厂商 vendor 分区 / pmOS adreno 包提取设备专用 zap）
- 🔬 `qca/crnv21.bin`(4.6K)：蓝牙 NVM（仅当缺失才补；deb 若已带设备专用版则保留）

源默认 `gitlab.com/kernel-firmware`（kernel.org cgit 有 Anubis 拦截不可用），可用 `LINUX_FIRMWARE_BASE` 覆盖；下载失败自动跳过、不阻断构建。
**重建刷机后需用 `device-probe.sh` 复测**：dmesg 不再报 sqe/crbtfw 缺失、GPU 不再 fault、`hciconfig hci0 up` 成功。
