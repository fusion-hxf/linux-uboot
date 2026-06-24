# raphael (Redmi K20 Pro / sm8150) 音频 Bring-up 计划

> 状态：调研完成，待设备采集 + DTS 起草。最后更新：2026-06-24
> 一句话：**音频可修，修复点在内核 DTS + 两个 Kconfig，不在 U-Boot、不在本 rootfs 仓库。**
> 这是 sm8150 整代 SoC 的开放任务（mainline 无任何 sm8150 设备接了 WCD9340 声卡），不是 raphael 单独落后。

---

## 1. 根因（源码级已确认）

设备症状（`device-probe.sh` §15）：
```
q6asm-dai 17300000.remoteproc:glink-edge:apr:apr-service@7:dais: No dais found in DT
q6asm-dai ... probe with driver q6asm-dai failed with error -22
→ /proc/asound/cards = no soundcards
```

源码链条：
- **base `sm8150.dtsi` 只给空骨架**：
  - `q6asmdai: dais { compatible="qcom,q6asm-dais"; ... }` — **无任何 `dai@N` 子节点**（line ~4476）
  - `sound: sound { };` — **完全空的 label 占位**（line ~4763，故 `/proc/device-tree/sound` 的 compatible 为空）
- **`sm8150-xiaomi-raphael.dts` 对音频贡献 = 0 个节点**：只 `#include "sm8150.dtsi"` + 3 个 pmic，仅在 pinctrl 里声明了 codec 引脚（见下），从未实例化 sound/codec/q6asm。

→ 这是 mainline qcom 的约定：`.dtsi` 给空壳，音频整套留给**板级 dts** 填；raphael 这份移植**没做音频 bring-up**（引脚铺好，节点没接）。

内核源：`https://github.com/GengWei1997/linux.git` 分支 `raphael-7.1`
（构建封装在本仓库同级 `kernel-deb/`：`raphael-kernel_build.sh` + `raphael.config` + `builddeb.patch`）

---

## 2. 内核配置侧现状（大部分已就绪，差 1 个 codec 驱动）

`kernel-deb/raphael.config` 实测：

| 组件 | 状态 |
|---|---|
| 声卡 machine 驱动 `SND_SOC_SM8150` | ✅ `=m` |
| APR `QCOM_APR` | ✅ `=y` |
| SLIMBus `SLIMBUS` + `SLIM_QCOM_NGD_CTRL` | ✅ `=y` |
| TFA9872 功放 `SND_SOC_TFA9872` | ✅ `=m` |
| **WCD934x codec `MFD_WCD934X` / `SND_SOC_WCD934X`** | ❌ **未设 → 需补** |
| UCM（userspace 混音） | ✅ 已随 `alsa-xiaomi-raphael` 发：`ucm2/Xiaomi/raphael/HiFi.conf` |

**Kconfig 待加**：`CONFIG_MFD_WCD934X=m`、`CONFIG_SND_SOC_WCD934X=m`（SLIMBus 已 `=y`；按需 `CONFIG_REGMAP_SLIMBUS`/`SOUNDWIRE` 等依赖）。

---

## 3. 意图拓扑（来自 UCM `HiFi.conf`，作者 Degdag Mohamed）

- **听筒 / 耳机 / 麦克** → **WCD934x（tavil）** codec，走 SLIMBus
  - 耳机：MultiMedia2 ↔ SLIMBUS_6_RX（AIF4_PB, RX2, RX3）
  - 底麦：MultiMedia3 ↔ SLIMBUS_1_TX；耳机麦：MultiMedia5 ↔ SLIMBUS_2_TX
- **内置扬声器** → **TFA9872** 功放，MultiMedia1 ↔ **QUAT_MI2S_RX**
- 前端：q6asm **MultiMedia1–5** DAI；后端：q6afe（QUAT_MI2S_RX / SLIMBUS_*）

UCM 控件名（`RX INT1_2 MUX` / `SLIM RX2 MUX` / `QUAT_MI2S_RX Audio Mixer`）都是 WCD934x + q6routing 的 **mainline 控件名** → 说明 userspace 是按 mainline 声卡写的，很可能有人在某 WIP 树真拉起来过。

---

## 4. 接线拼图清单（自己接线需要哪些信息）

模板 = **db845c（sdm845，同 WCD9340 / 同 APR 架构，mainline 完整可用）**。

| 拼图 | 内容 | 来源 | 设备可采? |
|---|---|---|---|
| A 前端 DAI | `&q6asmdai` 加 `dai@0..5`(MM1–5) | db845c 模板 + UCM | ✅ 无需采集 |
| B 后端 DAI | `&q6afedai`: QUAT_MI2S_RX、SLIMBUS_6_RX、SLIMBUS_1/2/5_TX | UCM 已列全 | ✅ 已有 |
| C 声卡节点 | `&sound` compatible=`qcom,sm8150-sndcard` + model + audio-routing + dai-link | db845c 模板 + UCM | ✅ 可拼 |
| D WCD934x | SLIMBus **elemental 地址**、reset/IRQ GPIO、供电、SoundWire 子节点 | 下游 DTB（地址）+ raphael.dts pinctrl 已有 GPIO | ⚠️ 部分（SLIM 地址需下游） |
| E TFA9872 | I2C 总线 + **地址**、reset GPIO、接 QUAT_MI2S | **i2cdetect 可扫** + 下游 DTB | ✅ 地址可采 |
| F 引脚 | QUAT MI2S pinmux | sm8150.dtsi pinmux 组 + 下游 | ✅ 可采 |
| G 供电 | codec/amp 的 vdd-*/micbias 引哪些 regulator | 下游 DTB | ⚠️ 需下游 |

**raphael.dts 已声明的 codec 引脚**（pinctrl，可直接复用）：
`CODEC_INT1_N=GPIO123`、`CODEC_INT2_N=GPIO124`、`CODEC_RST_N=GPIO143`、
`CODEC_SLIMBUS_CLK=GPIO149`、`CODEC_SLIMBUS_DATA0=GPIO150`、`DATA1=GPIO151`、`BT_FM_SLIMBUS=GPIO153/154`。

---

## 5. 设备采集（已就绪的工具）

仓库根 **`audio-collect.sh`**（只读）。设备上：
```
sudo bash audio-collect.sh 2>&1 | tee audio-info.txt   # 贴回
```
采集 7 块：声卡现状 / **SLIMBus 枚举(codec 地址)** / **i2cdetect(功放地址)** / codec 引脚 / DT q6 骨架 / **下游 DTB 分区线索** / 供电域。
（第 2 节用 `i2cdetect -y -r` 只读探测，对功放/codec 安全；顾虑可注释，改用下游 DTB 地址。）

**最权威的一次性来源 = 设备里残留的下游 MIUI DTB**：
```
ls -l /dev/disk/by-partlabel/ | grep -iE 'dtbo|boot|vendor'
dd if=/dev/disk/by-partlabel/dtbo_a of=/tmp/dtbo.img bs=1M
dtc -I dtb -O dts /tmp/dtbo.img > /tmp/dtbo.dts   # 或 python3 extract-dtb
# 取其中 sm8150-audio-overlay 段：tavil elemental-addr / TFA i2c 地址 / reset gpio / 供电
```

---

## 6. 社区 / 上游进展（调研结论）

- **`gitlab.com/sm8150-mainline/linux`** = sm8150 主线化总枢纽（raphael / 小米 Pad5 / OnePlus7 / Sony；GengWei1997 fork 自它）。
  全仓搜 `qcom,sm8150-sndcard` / `q6asmdai` = **0 命中**；其 raphael.dts(6.17, 1086 行)亦无音频。
- **确证：mainline + 所有 WIP 树，无任何 sm8150 设备接了 WCD9340 声卡。**
- 高通 QDSP6/ADSP 音频栈**成熟**（Linaro Srinivas Kandagatla 2018 起主线化；AudioReach/q6apm 2021；USB offload Linux 6.16）。
  **ADSP 固件不是瓶颈**：raphael 上 adsp remoteproc running、APR 工作、`q6afe-dai`/`q6routing` 已 bind。
  注意路线：sm8150 走**老的 APR/q6asm**（DTS 用的就是它），新 SoC 才走 AudioReach → 模板取 db845c，别取新 SoC。
- 参照：① **db845c** 完整声卡（结构模板）；② **realme5 下游** `sm8150-audio-overlay.dtsi`（接线"形状"：tavil 挂 `slim_aud`、`elemental-addr=[00 00 50 02 17 02]`、TFA 挂 qup i2c）；③ **raphael 自己的下游 MIUI DTS**（真值，从设备 DTB 或正确的 raphael 下游分支取）。

---

## 7b. 已恢复的下游接线（权威，来自 LineageOS android_kernel_xiaomi_sm8150, lineage-22.2）

> 注意：本机刷机时 `fastboot erase dtbo/boot` + 刷 U-Boot，**设备上的下游 DTB 已被擦除/覆盖**
> （boot 现在是 U-Boot 附带的 mainline DTB，dtbo 为空）。接线改从 GitHub 下游源恢复，已全部取到。
>
> 来源链：`arch/arm64/boot/dts/qcom/raphael-sm8150-overlay.dts` →
> `xiaomi/overlay/raphael/raphael-sm8150.dtsi`(硬件) + `.../raphael-audio-overlay.dtsi`(声卡) +
> `xiaomi/overlay/common/sm8150-audio-overlay.dtsi`(QUAT MI2S pinctrl)

### 扬声器功放 TFA98xx（raphael-sm8150.dtsi）
- `compatible = "nxp,tfa98xx"`，挂 **qupv3_se1_i2c**，`reg = <0x34>`
- `reset-gpio = <&tlmm 59 0>`（SPKR_PA_RST = GPIO59）
- `irq = <&tlmm 141 0>`，interrupt-names "smartpa_irq"（SPKR_INT = GPIO141）
- 音频走 **QUAT MI2S**（quat_mi2s_sd0/sd1）——印证 UCM 的 `QUAT_MI2S_RX`
- 单颗（mono 底部扬声器）
- mainline 驱动用 `SND_SOC_TFA9872`（compatible `nxp,tfa9872`）；需确认 raphael 实际 TFA 型号兼容

### codec WCD9340（tavil / snd_934x）
- SLIMBus；**mainline 用标准 `compatible="slim217,250"`**（manufacturer 0x217=高通，product 0x250=WCD9340，通用，无需设备特定 elemental 地址）
- reset = CODEC_RST_N = **GPIO143**；INT1=**GPIO123**，INT2=**GPIO124**；SLIMBus CLK/DATA0/DATA1=**GPIO149/150/151**
- `qcom,wsa-max-devs=0`（无 WSA，扬声器交给 TFA via MI2S）
- audio-routing：`"hifi amp"←LINEOUT1/2`；AMIC1-5 + MIC BIAS1-4；Headset Mic；ANC mics

### 其它
- USB-C 模拟耳机切换 `fsa4480@43` on qupv3_se4_i2c（耳机孔走 USB-C，可后续加 typec-mux）

### 仍需精修（起草时处理）
- WCD9340 各 `*-supply` 的 pm8150 轨映射（取自 db845c 模板 + 设备实测 `vreg_s4a_1p8=1.8V`；或下游 sm8150-audio.dtsi base）
- 确认 raphael 的 TFA 具体型号与 mainline `tfa9872`/`tfa989x` 驱动的兼容性
- QUAT MI2S 在 mainline sm8150.dtsi 的 pinmux 组名

---

## 7c. 下一步 Action（续作清单）

- [x] 设备上跑 `audio-collect.sh`（确认 SLIMBus 空 / codec/amp 未声明 / 配置缺 WCD934x）
- [x] 下游接线恢复（设备 DTB 已擦，改从 LineageOS 源取齐，见 §7b）
- [x] 起草音频 DTS → `audio-dts-draft/sm8150-xiaomi-raphael-audio.dtsi`（以 db845c 为骨架 + §7b 接线）
- [ ] 在内核源树应用草稿 + 改 `raphael.config`（见 `audio-dts-draft/README.md`），编译
- [ ] 阶段1 验证：声卡注册 / `q6asm-dai` bind（`device-probe.sh §15` 应翻为 `audio=ok`）
- [ ] 阶段2 验证：收敛 pinctrl/routing TODO，UCM 加载放音/录音
- [ ] `raphael.config` 加 `CONFIG_MFD_WCD934X=m` + `CONFIG_SND_SOC_WCD934X=m`
- [ ] 本地编译（照 `kernel-deb/raphael-kernel_build.sh`）→ 验证 `q6asm-dai` bind、声卡注册、`aplay -l` 有卡
- [ ] UCM 已就绪，声卡起来后直接验证播放/录音通路
- [ ] 成功后考虑上游 sm8150-mainline（这是整代 SoC 的缺口，有上游价值）

## 关键链接

- 内核源：https://github.com/GengWei1997/linux （分支 raphael-7.1）
- sm8150 主线枢纽：https://gitlab.com/sm8150-mainline/linux
- db845c 参照：torvalds/linux `arch/arm64/boot/dts/qcom/sdm845-db845c.dts`
- realme5 下游接线：https://github.com/realme-kernel-opensource/realme5-kernel-source `.../19631/sm8150-audio-overlay.dtsi`
- pmOS raphael wiki：https://wiki.postmarketos.org/index.php?title=Xiaomi_Mi_9T_Pro_/_Redmi_K20_Pro_(xiaomi-raphael)
- 采集工具：本仓库 `audio-collect.sh`；诊断工具：`device-probe.sh` §15（音频根因定位）
