# raphael 音频 DTS 草稿 — 应用与验证

本目录是 raphael(sm8150)音频 bring-up 的 DTS 草稿。背景/根因/接线来源见仓库根
`audio-bringup-plan.md`(尤其 §7b 已恢复的下游接线)。

## 文件

- `sm8150-xiaomi-raphael-audio.dtsi` — 音频节点草稿(前端/后端 DAI、声卡 machine、
  WCD9340 codec、TFA9872 功放、pinctrl 占位)。

## 如何应用(在 fusion-hxf/linux raphael-7.1 源码树里)

1. 把草稿放到 `arch/arm64/boot/dts/qcom/sm8150-xiaomi-raphael-audio.dtsi`。
2. 在 `arch/arm64/boot/dts/qcom/sm8150-xiaomi-raphael.dts` 顶部头文件区加：
   ```
   #include <dt-bindings/sound/qcom,q6asm.h>
   ```
   （`qcom,q6afe.h`、`gpio.h`、`irq.h` 已被 sm8150.dtsi 引入。）
3. 在该 `.dts` 末尾追加：
   ```
   #include "sm8150-xiaomi-raphael-audio.dtsi"
   ```

## 内核配置改动(`kernel-deb/raphael.config`)

```
CONFIG_MFD_WCD934X=m
CONFIG_SND_SOC_WCD934X=m
CONFIG_REGMAP_SLIMBUS=y        # 若未自动选上
CONFIG_SND_SOC_TFA9872=m       # 已有(GengWei 树自带 tfa9872 驱动)
CONFIG_SND_SOC_SM8150=m        # 已有(声卡 machine)
```
WCD9340 走 SoundWire 子总线，按需确认 `CONFIG_SOUNDWIRE=m` / `CONFIG_SOUNDWIRE_QCOM=m`。

## 编译

照 `kernel-deb/raphael-kernel_build.sh` 的流程(`make ARCH=arm64 LLVM=-22 defconfig raphael.config`
→ `make ... deb-pkg`)，或本地 `make ARCH=arm64 ...` 出 dtb 验证。

## 分阶段验证

### 阶段 1 — 声卡先注册(首要目标)
判据：`/proc/asound/cards` 出现声卡；dmesg 不再有
`q6asm-dai ... No dais found in DT / failed with error -22`。
- 卡的注册只依赖节点结构合法，**pinctrl/routing 不全也能注册**。
- 设备上复跑 `device-probe.sh §15` 应从 `audio=dtb_missing_dais` 翻为 `audio=ok`。

### 阶段 2 — 音频真正出声/录音
判据：`aplay -l` 有卡，UCM(已随 alsa 包发)加载后能放音/录音。
需要把以下 TODO 收敛准确。

## TODO 核对清单(草稿里已标 /* TODO */)

| 项 | 说明 | 取值来源 |
|---|---|---|
| QUAT MI2S pinctrl | `quat_mi2s_active/_sleep` 的准确 GPIO/function | 下游 raphael pinctrl(SPKR_I2S_BCK/WS/DOUT/DIN)或 sm8150 标准 mi2s 组 |
| rpmhcc LN_BB_CLK2 | 确认 sm8150 rpmhcc 有此时钟作 codec mclk | sm8150 rpmhcc 绑定 |
| TFA 型号 | `nxp,tfa9872` vs `nxp,tfa9874`(驱动两者都认) | 设备实测/下游 |
| TFA reset 属性名 | 确认 tfa9872 驱动读 `reset-gpios` | GengWei tfa9872.c |
| WCD AIF 路由 | 阶段2 按 UCM 改 SLIMBUS_6_RX(耳机)/1,2,5_TX(麦) | UCM HiFi.conf |
| audio-routing widget | 逐条核对 mainline wcd934x widget 名 | wcd934x 驱动 |
| 供电轨 | 全用 `vreg_s4a_1p8`(同 db845c，设备实测存在)；如报缺压再调 | dmesg |

## 已确定的硬件事实(无需再查)

- 功放：NXP TFA9872，`&i2c1`(QUP SE1, i2c@884000)@ 0x34，reset=GPIO59，irq=GPIO141，走 QUAT MI2S。
- codec：WCD9340，SLIMBus `&slim`(slim-ngd@171c0000，默认 disabled→已 enable)，
  标准 `slim217,250`，reset=GPIO143，int=GPIO123，供电 vreg_s4a_1p8。
- 骨架：`&q6asmdai`/`&q6afedai`/`&q6routing`/`&sound` 标签均在 sm8150.dtsi，本草稿填充之。
