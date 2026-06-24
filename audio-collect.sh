#!/bin/bash
# =============================================================================
# audio-collect.sh — 为 raphael (sm8150) 音频 DTS bring-up 采集硬件接线信息
# =============================================================================
# 背景：mainline 全系 sm8150 设备都没有接 WCD9340 声卡（sm8150.dtsi 里 sound{} 是空壳、
#       q6asmdai 无 dai 子节点）。要自己接线，需要拿到 raphael 的具体接线参数。
#       本脚本【只读】采集设备侧能直接拿到的那部分，其余需下游 MIUI DTS 补齐。
#
# 用法：  sudo bash audio-collect.sh 2>&1 | tee audio-info.txt   然后把 audio-info.txt 贴回
# 注意：第 2 节会用 i2cdetect 只读(-r)探测 I2C，正常对功放/codec 安全；若设备正在跑关键任务可注释掉。
# =============================================================================
export LANG=C LC_ALL=C
S(){ printf '\n===== %s =====\n' "$*"; }
have(){ command -v "$1" >/dev/null 2>&1; }

S "0. 内核 / 声卡现状"
uname -r
echo "asound/cards:"; cat /proc/asound/cards 2>/dev/null

S "1. SLIMBus 枚举 —— WCD9340(tavil) 的 codec 逻辑地址(接线关键)"
ls -l /sys/bus/slimbus/devices/ 2>/dev/null || echo "  无 /sys/bus/slimbus（slim_ngd 未起?）"
for d in /sys/bus/slimbus/devices/*; do
  [ -e "$d" ] || continue
  echo "-- $(basename "$d")"
  for f in name modalias driver_override; do [ -e "$d/$f" ] && echo "   $f=$(cat "$d/$f" 2>/dev/null)"; done
done
echo "-- dmesg slim/wcd/tavil:"; dmesg 2>/dev/null | grep -iE 'slim|ngd|tavil|wcd|aud' | tail -20 | sed 's/^/   /'

S "2. I2C 总线 + 扫描 —— 找 TFA9872 功放地址(只读 -r 模式)"
have i2cdetect && i2cdetect -l 2>/dev/null
if have i2cdetect; then
  for b in $(i2cdetect -l 2>/dev/null | sed -n 's/^i2c-\([0-9]\+\).*/\1/p'); do
    echo "-- bus $b:"; timeout 8 i2cdetect -y -r "$b" 2>/dev/null | sed 's/^/   /'
  done
else echo "  i2cdetect 未安装（apt install i2c-tools）"; fi
echo "-- 已绑定的 i2c 设备:"; ls /sys/bus/i2c/devices/ 2>/dev/null | sed 's/^/   /'

S "3. codec/amp 引脚 —— DTS 已声明 CODEC_INT/RST/SLIMBus，需补 MI2S/SPK"
for p in /sys/kernel/debug/pinctrl/*/pinmux-pins; do
  [ -r "$p" ] || continue; echo "== $p"
  grep -iE 'CODEC|MI2S|SLIM|spkr|spk|tfa|aud' "$p" 2>/dev/null | sed 's/^/   /'
done
echo "-- gpio 名:"; grep -iE 'CODEC|MI2S|spk|tfa|aud' /sys/kernel/debug/gpio 2>/dev/null | sed 's/^/   /'

S "4. DT 里 apr/q6 音频服务现状(确认骨架在、子节点缺)"
for n in q6afe q6asm q6adm sound; do
  echo "-- 匹配 *$n*:"; find /proc/device-tree -maxdepth 6 -iname "*$n*" 2>/dev/null | sed 's/^/   /' | head
done

S "5. 已加载/可用的 codec/amp 驱动"
echo "-- lsmod:"; lsmod 2>/dev/null | grep -iE 'wcd|tfa|tas|cs35|snd_soc|slim' | sed 's/^/   /'
echo "-- platform drivers:"; ls /sys/bus/platform/drivers/ 2>/dev/null | grep -iE 'wcd|tfa|q6|sm8150|slim' | sed 's/^/   /'

S "6. 下游 MIUI DTB 提取线索 —— 含完整音频接线的权威来源"
echo "-- 分区标签(找 dtbo/boot/vendor 以反编译下游 DT):"
ls -l /dev/disk/by-partlabel/ 2>/dev/null | grep -iE 'dtbo|boot|vendor|dtb|super' | sed 's/^/   /' || echo "   无 by-partlabel"
cat <<'EOF'
   若存在 dtbo_a / boot_a / vendor_a，可在设备上(谨慎、只读 dd)：
     dd if=/dev/disk/by-partlabel/dtbo_a of=/tmp/dtbo.img bs=1M
     # 然后用 dtc -I dtb -O dts，或 python3 extract-dtb，反编译出
     # sm8150-audio-overlay 段(tavil codec elemental-addr / TFA i2c 地址 / reset gpio / 供电)
EOF

S "7. 供电域 —— codec/amp 的 vdd，DTS 需引用"
for r in /sys/class/regulator/regulator.*; do
  [ -e "$r/name" ] || continue
  printf '   %-22s %s\n' "$(cat "$r/name" 2>/dev/null)" "$(cat "$r/microvolts" 2>/dev/null)"
done | grep -iE 'l[0-9]|s[0-9]|bob|vdd|cdc|micb|codec|spk|aud' | head -40

S "完成"
echo "把本输出整段贴回；结合下游 DTB(第6节)即可拼出完整音频 DTS。"
