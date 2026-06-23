# GitHub Actions 云端构建完整指南

> 用 GitHub 的免费 **ARM runner** 在云端构建小米 raphael(Redmi K20 Pro)的 Debian/Ubuntu 镜像，
> 无需本地 root 环境。本指南覆盖：Fork → 推送改动 → 触发构建 → 参数详解 → 取产物 → 刷机 → 复测。

---

## 0. 工作原理(先理解，少踩坑)

- 构建在 `.github/workflows/build-system.yml` 里，名字叫 **「构建系统镜像」**。
- 它跑在 `ubuntu-24.04-arm` 上：下载外部内核/固件/boot.img → 跑 `build.sh` → 打包 `.7z`+`.sha256` →
  汇总发布到一个名为 **`latest`** 的 Release。
- **CI 构建的是“仓库里此刻的脚本”**。本仓库的优化(DNS 收口、身份唯一化、内核同步钩子、earlyoom、
  watchdog、regulatory.db 修复、固件补齐……)都在 `scripts/`、`config/` 里 —— **不 push 就不会进镜像**。

---

## 1. 准备：Fork + 推送你的改动（关键）

1. 右上角 **Fork** 把本仓库复制到你自己的账号。
2. 把本地的优化改动提交并推到你的 fork（否则云端构建仍是未优化版本）：

   ```bash
   git add -A
   git commit -m "apply P0/P1 + firmware backfill optimizations"
   # 推到你 fork 的某个分支（例如 master 或 main）
   git push origin master
   ```

   > 触发构建时可以在 “Run workflow” 里**选择这个分支**，所以推到哪个分支都行，记住分支名即可。
3. 进入 fork 的 **Actions** 页，如提示需要启用 workflow，点 **“I understand… enable”**。

---

## 2. 触发一次构建（出镜像只走这条路）

**务必用手动触发 “Run workflow”（workflow_dispatch）**，不要指望 push 自动出镜像（原因见 §7 第 1 条）。

1. fork 仓库 → **Actions** → 左侧选 **「构建系统镜像」**。
2. 右上 **Run workflow** 下拉：
   - **Use workflow from**：选你 §1 push 的分支。
   - 按需填下面的参数（§3）。
3. 点 **Run workflow**，等待矩阵任务跑完（每个镜像约 10–25 分钟）。

---

## 3. 参数详解

| 参数(UI 标签) | 默认 | 含义 / 建议 |
|---|---|---|
| `build_mode`（构建模式） | `parallel` | `parallel`=按各参数笛卡尔积**批量**构建；`single`=只取每个参数的**第一个值**构建一个镜像（最快，适合验证） |
| `system_types`（系统类型） | Ubuntu 3 种 | 默认 `ubuntu-server,ubuntu-gnome,ubuntu-phosh`；要 Debian 或单个自行填，取值见下方 |
| `kernel_versions`（内核版本） | `7.1` | 默认已是 7.1；须在 `kernel_repository` 有对应 `kernel-v<版本>` release（如 `kernel-v7.1`） |
| `bootstrap_tools`（构建工具） | `mmdebstrap` | `mmdebstrap`(快) 或 `debootstrap` |
| `desktop_environments`（桌面环境） | `phosh-core` | 仅对 `*-phosh` 生效：`phosh-core`/`phosh-full`/`phosh-phone` |
| `debian_versions`（Debian 版本） | `trixie` | 仅对 `debian-*` 生效 |
| `ubuntu_versions`（Ubuntu 版本） | `resolute` | 仅对 `ubuntu-*` 生效（resolute = 26.04） |
| `kernel_repository`（内核包仓库） | `GengWei1997/kernel-deb` | 预编译内核/固件/boot 来源。**保持默认**（你不自己编内核） |

**`system_types` 可选值**：`debian-server` / `debian-gnome` / `debian-phosh` / `ubuntu-server` / `ubuntu-gnome` / `ubuntu-phosh`。

> 注意：你实际在用的 **KDE Plasma** 不在这套矩阵里（构建脚本没有 plasma 选项）；矩阵只产出上面 6 类。
> 想要 Plasma 需在 `scripts/06-install-all-packages.sh` 自行加桌面包，超出本指南范围。

---

## 4. 常用场景

**A. 最快验证我们的优化（推荐先做）** —— 单镜像、服务器版、内核 7.1：
```
build_mode         = single
system_types       = ubuntu-server
kernel_versions    = 7.1
ubuntu_versions    = resolute
bootstrap_tools    = mmdebstrap
kernel_repository  = GengWei1997/kernel-deb
```

**B. Ubuntu Phosh 移动桌面、7.1**：
```
build_mode = single
system_types = ubuntu-phosh
kernel_versions = 7.1
desktop_environments = phosh-core
ubuntu_versions = resolute
```

**C. 批量全量（耗时长）**：`build_mode=parallel`，`system_types` 保留 6 种，`kernel_versions=7.1`。

---

## 5. 取构建产物

- **每个矩阵任务**：在该 run 页面底部 **Artifacts** 下载，文件名形如
  `rootfs-<系统类型>-<内核>-<系统版本>[-<phosh变体>]`（含 `.7z` + `.sha256`，**保留 7 天**）。
- **手动触发**还会把所有结果汇总发布到 fork 的 **Releases → `latest`**。
- **超过 2GB 的镜像**（如 `ubuntu-gnome`）不进 Release，**只在 Artifacts**。
- 校验：`sha256sum -c <文件>.sha256`。

---

## 6. 刷机

解压 `.7z` 得到 `rootfs.img` 与 `xiaomi-k20pro-boot.img`；`u-boot.img` 从
[linux-xiaomi-raphael-uboot 的 Releases](https://github.com/GengWei1997/linux-xiaomi-raphael-uboot/releases)（取最近日期版本）下载。

```bash
adb reboot bootloader
fastboot erase dtbo
fastboot erase boot
fastboot erase cache
fastboot erase userdata
fastboot flash cache  xiaomi-k20pro-boot.img   # 内核+initramfs(/boot)
fastboot flash boot   u-boot.img               # 引导
fastboot flash userdata rootfs.img             # 根文件系统
fastboot reboot
```

> 承重不变量：rootfs 的固定 UUID `ee8d3593-59b1-480e-a3b6-4fefb17ee7d8` 必须与 boot.img 里
> `root=UUID=…` 一致（本仓库 `16-finalize.sh` 已固化），否则不开机。首次开机会自动扩容 `/` 到整块 userdata。

---

## 7. 复测（验证优化是否生效）

刷机后在设备上跑仓库根的诊断脚本，对照优化项确认：
```bash
sudo bash device-probe.sh    # 生成 raphael-report-*.txt，贴回即可
```
重点看：`resolv.conf` 已收口 resolved、SSH host key 指纹是本机新生成（非 `root@runnervm…`）、
earlyoom 运行、`RuntimeWatchdogSec` 已开、dmesg 不再报 `regulatory.db` / `a630_sqe.fw` / `crbtfw21.tlv` 缺失。

---

## 8. 常见问题 / 坑

1. **push 自动构建出不了镜像** —— 工作流虽对 `scripts/**` 等 push 触发，但 push 时没有手动输入参数，
   生成的构建矩阵为空、且 `KERNEL_REPO` 会回退到错误仓库。**出镜像务必用 “Run workflow”。**
2. **默认已是内核 7.1 + Ubuntu resolute(26.04)** —— 如需 7.0/6.18 或 Debian，在表单里改对应参数即可。
3. **`kernel-v<版本>` release 必须齐全** —— `kernel_repository` 对应 tag 下需有
   `linux-image-/linux-headers-/firmware-xiaomi-raphael.deb`；桌面版(`*-gnome`/`*-phosh`)还需
   `alsa-xiaomi-raphael.deb`，缺了会构建失败。
4. **固件补齐需联网** —— 我们新增的通用固件补齐(`09`)会从 `gitlab.com/kernel-firmware` 拉取；
   GitHub 官方 runner 有外网，正常。自建国内 runner 若拉不动，可在 workflow 的 build 步骤设环境变量
   `LINUX_FIRMWARE_BASE=<可用镜像>`。
5. **构建失败排查** —— 打开失败的矩阵任务，看 “执行构建” 步骤日志；`build.sh` 各阶段都有 `[NN]` 前缀便于定位。
6. **没有 GitHub Token 配置烦恼** —— Release 发布用内置 `GITHUB_TOKEN`，fork 下默认可用，无需手配。

---

## 9. 本地构建（等价参考）

不想用 CI 也可本地复刻（需 root + loop mount，见 `README.md` / `CLAUDE.md`）：
```bash
bash scripts/00-download-deps.sh 7.1 GengWei1997/kernel-deb
sudo BOOTSTRAP_TOOL=mmdebstrap UBUNTU_VERSION=resolute ./build.sh ubuntu-server 7.1
```
