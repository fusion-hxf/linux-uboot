# Raphael Rootfs Image Builder

本仓库只保留系统镜像构建与 CI 发布相关内容，用于为 Xiaomi Redmi K20 Pro / Mi 9T Pro（`raphael` / `sm8150`）装配 Debian / Ubuntu rootfs。

它不维护内核源码，也不维护 U-Boot 源码。内核、固件、ALSA 配置和 boot image 来自外部 release；本仓库负责下载这些产物、创建 rootfs、写入设备配置，并在 GitHub Actions 中打包发布镜像。

默认内核版本 `7.1` 当前包含音频 bring-up 和受安全门控的 Venus 诊断代码。Venus 不会在默认加载时探测 Iris1，只有手工传入 `allow_iris1_probe=1` 才会触碰硬件。

## 保留内容

| 路径 | 用途 |
| --- | --- |
| `build.sh` | 本地 rootfs 构建入口 |
| `config/build-config.sh` | 系统类型、镜像大小、发行版源配置 |
| `scripts/00-download-deps.sh` | 下载内核 deb、ALSA 配置、cache boot image 和 U-Boot |
| `scripts/01-16` | rootfs 创建、bootstrap、系统配置、内核安装和收尾 |
| `tools/raphael-venus-probe.sh` | 在持久日志启动后手动探测实验性 Venus 驱动 |
| `.github/workflows/build-system.yml` | rootfs 镜像 CI 构建和 release |
| `.github/workflows/build-uboot.yml` | 实验性的 U-Boot boot image 构建 |
| `repack-uboot.py` | 复用已知可启动 U-Boot 二进制，只替换追加 DTB |

历史调研、诊断脚本和报告已迁到聚合仓库根目录：

- `docs/build-kernel-2-image/`
- `docs/reports/`
- `tools/`

## Venus 手工诊断

`tools/raphael-venus-probe.sh` 的默认资源组合已恢复为历史保守值：200 MHz、`video-mem=2500 kB/s`、不显式应用 OPP、不获取 `video-processor` ICC。新增 Stage 8 会复现曾经到达 firmware boot-ready 的 unmasked 顺序；脚本会先启动持久 kmsg，并把结果写到 `/home/user/venus-bringup/`。

建议先以 `VENUS_RUN_STAGE=5 VENUS_IRQ_ACK_STAGE=0` 验证未触发固件时的资源和清理，再在完整重启后以 `VENUS_RUN_STAGE=6 VENUS_IRQ_ACK_STAGE=8` 验证 legacy-exact。详细命令、风险边界和当前证据见聚合仓库根目录 `README.md` 的“GPU / Venus 视频驱动进展”章节。显式 OPP 与 processor ICC 必须分别单独打开，避免一个用例同时改变两个变量。

## 本地构建

下载入口需要 `curl`、`unzip`、`dpkg-deb`、Python 3 和 `fdtget`；Debian/Ubuntu 可安装
`device-tree-compiler` 提供 `fdtget`。

先下载内核包、cache boot image 和 U-Boot：

```bash
bash scripts/00-download-deps.sh 7.1 fusion-hxf/kernel-deb
```

该脚本会下载并校验：

- `linux-image-xiaomi-raphael.deb`
- `linux-headers-xiaomi-raphael.deb`
- `firmware-xiaomi-raphael.deb`
- `alsa-xiaomi-raphael.deb`
- `xiaomi-k20pro-boot.img`
- `u-boot.img` / `u-boot-safe.img`
- `u-boot-audio-test.img`
- `u-boot-venus-test.img`
- `u-boot-bringup-test.img`
- `u-boot-variants.tsv`（包含 DTB 首个 `compatible` 与 SHA-256）

这些镜像复用 GengWei v1.0.0 U-Boot 二进制，仅替换 control DTB。其首个
`compatible` 决定 U-Boot 随后从 `/boot/dtbs/qcom/` 加载哪一份 Linux DTB；构建会用
`fdtget` 校验 safe、audio、Venus 和 combined 四个选择键，防止实验镜像仍加载 safe DTB。

构建默认 Ubuntu Server 镜像：

```bash
sudo BOOTSTRAP_TOOL=mmdebstrap UBUNTU_VERSION=resolute ./build.sh ubuntu-server 7.1
```

构建 Phosh 镜像：

```bash
sudo BOOTSTRAP_TOOL=mmdebstrap UBUNTU_VERSION=resolute ./build.sh ubuntu-phosh 7.1 phosh-core
```

构建脚本需要 root 权限，因为会创建 loop 设备、挂载 rootfs、bind mount `/dev`、`/proc`、`/sys` 并 chroot。

默认产物为 Android sparse 格式的 `rootfs.img`。CI 会将其与 `xiaomi-k20pro-boot.img`、`u-boot.img` 一起打包为 `.7z`，并生成压缩包 `.sha256` 和内容 `.contents.sha256`，再按输入决定是否发布到 GitHub Release。

## 持久化 `/home`

默认启用 `PERSISTENT_HOME=1`。镜像会固定 `/` 的 ext4 大小，不再通过 `x-systemd.growfs` 吃满整个 `userdata` 分区；启动时由 `raphael-persistent-home.service` 把 `userdata` 分区 `16G` 之后的空间映射为 loop ext4，并挂载到 `/home`。

默认布局：

```text
userdata
├── 0 - IMAGE_SIZE       /
├── IMAGE_SIZE - 16G     预留空洞，便于 rootfs 后续增长
└── 16G - end            /home
```

关键参数：

- `PERSISTENT_HOME=1`：启用持久 `/home`。
- `PERSISTENT_HOME_OFFSET=16G`：`/home` 起始 offset。已有数据后不要随意修改。
- `PERSISTENT_HOME=0`：回到旧行为，`/` 使用 `x-systemd.growfs` 扩到整个 `userdata`。

保留 `/home` 的刷机方式：

```bash
fastboot erase boot
fastboot erase cache
fastboot erase dtbo
fastboot flash cache xiaomi-k20pro-boot.img
fastboot flash boot u-boot.img
fastboot flash userdata rootfs.img
```

不要执行 `fastboot erase userdata`，否则 `/home` 也会被清掉。初次切换到该方案时，允许清空一次 `userdata`，之后测试重刷 rootfs 时只执行 `fastboot flash userdata rootfs.img`。

## 支持的系统类型

- `debian-server`
- `debian-gnome`
- `debian-phosh`
- `ubuntu-server`
- `ubuntu-gnome`
- `ubuntu-phosh`

默认内核版本为 `7.1`，默认 Debian 版本为 `trixie`，默认 Ubuntu 版本为 `resolute`。

脚本现在会默认安装 ALSA 基础包、PipeWire、PipeWire Pulse 兼容层和 WirePlumber，并要求 `alsa-xiaomi-raphael.deb` 存在。默认用户会加入 `audio`、`video`、`render`、`input` 等设备相关组。Plasma 当前不是本构建矩阵的一部分；如需正式支持 Plasma，应新增独立系统类型并显式维护 Plasma 包集。

## CI 构建

`构建系统镜像` workflow 的默认输入是：

- `system_types`: `ubuntu-server`
- `kernel_versions`: `7.1`
- `bootstrap_tools`: `mmdebstrap`
- `kernel_repository`: `fusion-hxf/kernel-deb`
- `kernel_release_tag`: 留空，自动使用 `kernel-v<kernel_version>`

CI 会复用 `scripts/00-download-deps.sh` 下载依赖，再执行 `build.sh`。如果 ALSA 配置包缺失，构建会直接失败，避免生成缺少声卡用户态配置的镜像。

cache boot image 默认从 `GengWei1997/kernel-deb` 的 v1.0.0 release 下载；可通过 `BOOT_IMG_URL` 覆盖。

U-Boot 默认下载地址为 GengWei v1.0.0 release。构建会复用其中已验证可启动的 U-Boot 二进制，并用当前 `linux-image` deb 的 `sm8150-xiaomi-raphael.dtb` 重新打包；因此无需编译 U-Boot，也能让启动 DTB 与内核包匹配。可通过 `UBOOT_IMG_URL` 覆盖下载地址，或通过 `UBOOT_IMG` 修改最终镜像输出路径。

## 设备不变量

- rootfs 固定 UUID：`ee8d3593-59b1-480e-a3b6-4fefb17ee7d8`
- `/boot` 位于手机 `cache` 分区，刷入 `xiaomi-k20pro-boot.img`
- `boot` 分区刷入 `u-boot.img`
- USB NCM 地址：`172.16.42.1`
- 默认用户：`user` / `1234`
- 默认 root：`root` / `1234`
