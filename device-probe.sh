#!/bin/bash
# =============================================================================
# raphael (Redmi K20 Pro / sm8150) 综合诊断与能力检测 —— 生成分析报告
# =============================================================================
# 目的：在【已启动的设备】上一次性跑完优化方案需要的所有检测，输出带"判定+建议"
#       的分析报告。供据此进行实际优化（IPv6 恢复、watchdog 自愈、TRIM、内存兜底等）。
#
# 用法：  sudo bash device-probe.sh      （非 root 也能跑，但 dmesg / 部分 sysfs 受限）
# 产物：  ./raphael-report-<时间>.txt     （把该文件整段贴回 / 上传即可）
#
# 本脚本【只读】：不修改任何配置、不写设备、不自动 fstrim。
# =============================================================================

export LANG=C LC_ALL=C
TS="$(date +%Y%m%d-%H%M%S)"
REPORT="${PWD}/raphael-report-${TS}.txt"
touch "$REPORT" 2>/dev/null || REPORT="/tmp/raphael-report-${TS}.txt"
# [C3] 机器可读旁路 + 回归基线：  bash device-probe.sh --baseline <旧.kv>
BASELINE=""; [ "${1:-}" = "--baseline" ] && BASELINE="${2:-}"
KV="${REPORT%.txt}.kv"

# ---- 判定累加器 / 能力矩阵 ----
declare -a F_FAIL F_WARN F_INFO
declare -A CAP

c_ok()   { printf '  [OK]    %s\n' "$*"; }
c_warn() { printf '  [WARN]  %s\n' "$*"; F_WARN+=("$*"); }
c_fail() { printf '  [ISSUE] %s\n' "$*"; F_FAIL+=("$*"); }
c_info() { printf '  [INFO]  %s\n' "$*"; F_INFO+=("$*"); }
c_na()   { printf '  [--]    %s 不可用/未安装\n' "$*"; }
hdr()    { printf '\n========================= %s =========================\n' "$*"; }
sub()    { printf '\n--- %s ---\n' "$*"; }
have()   { command -v "$1" >/dev/null 2>&1; }
val()    { cat "$1" 2>/dev/null; }
num()    { printf '%s' "${1:-0}" | tr -cd '0-9'; }   # 提取数字，空->''

# 测量命令墙钟耗时（秒，3 位小数）；用 timeout 防止 DNS 坏时挂死
timed() {
  local s e; s=$(date +%s.%N 2>/dev/null)
  timeout 8 "$@" >/dev/null 2>&1
  e=$(date +%s.%N 2>/dev/null)
  awk -v a="$s" -v b="$e" 'BEGIN{ if(a==""||b==""){print "?"} else printf "%.3f", b-a }'
}
gt() { awk -v x="$1" -v y="$2" 'BEGIN{exit !((x+0)>(y+0))}'; }  # x>y ?

main() {
printf 'raphael 诊断报告  生成时间: %s\n' "$(date '+%F %T %Z')"
printf '主机: %s   用户: %s(uid=%s)\n' "$(hostname 2>/dev/null)" "$(id -un)" "$(id -u)"
[ "$(id -u)" -eq 0 ] || c_warn "未以 root 运行：dmesg / 部分 sysfs / iw 检测可能受限，建议 sudo 重跑"

# ───────────────────────────── 1. 系统概览 ─────────────────────────────
hdr "1. 系统概览"
uname -a
echo "cmdline : $(val /proc/cmdline)"
if have lsb_release; then lsb_release -d 2>/dev/null; else grep PRETTY_NAME /etc/os-release 2>/dev/null; fi
echo "设备DT  : $( [ -e /proc/device-tree/compatible ] && tr -d '\0' < /proc/device-tree/compatible 2>/dev/null )"
echo "运行时长: $(uptime -p 2>/dev/null || uptime)"
echo "CPU 数  : $(nproc 2>/dev/null)"

# ───────────────────────────── 2. 启动 & 服务健康 ─────────────────────────────
hdr "2. 启动与服务健康"
st=$(systemctl is-system-running 2>/dev/null)
case "$st" in
  running) c_ok "systemd 状态: running" ;;
  degraded) c_fail "systemd 状态: degraded（有服务失败，见下）" ;;
  *) c_warn "systemd 状态: ${st:-未知}" ;;
esac
sub "失败的服务 (systemctl --failed)"
failed=$(systemctl --failed --no-legend --plain 2>/dev/null)
if [ -n "$failed" ]; then echo "$failed"; c_fail "存在 failed 服务（上面列表）"; else c_ok "无 failed 服务"; fi

# [改进] degraded 但 --failed 为空 = 失败单元已恢复；回溯本次启动日志定位根因
if [ "$st" = degraded ]; then
  sub "降级根因追溯 (degraded 但当前无 failed → 查本次启动日志)"
  jl=$(timeout 15 journalctl -b --no-pager 2>/dev/null)
  cyc=$(printf '%s\n' "$jl" | grep -iE 'ordering cycle|deleting job' | head -6)
  trans=$(printf '%s\n' "$jl" | grep -iE 'entered failed state|Failed with result|Failed to start ' | tail -10)
  if [ -n "$cyc" ]; then
    c_fail "检出 ordering cycle（systemd 会非确定性删除某 job → degraded / 丢服务的根因）"
    printf '%s\n' "$cyc" | sed 's/^/    /'
  fi
  if [ -n "$trans" ]; then printf '  早启动期失败/已恢复单元:\n'; printf '%s\n' "$trans" | sed 's/^/    /'
  else c_info "本次启动日志未见显式失败单元（可能为一次性 Condition 跳过）"; fi
fi

# [改进] ordering cycle 可能非确定性地未拉起 ssh.socket → 直接核对 sshd 是否在监听
sub "SSH 可达性 (ordering cycle 可能导致 ssh.socket 未拉起)"
if have ss && ss -Hltn 'sport = :22' 2>/dev/null | grep -q .; then c_ok "sshd 正在监听 :22"
elif systemctl is-active ssh.socket >/dev/null 2>&1 || systemctl is-active ssh >/dev/null 2>&1; then c_ok "ssh.socket/ssh = active"
else c_warn "未见 :22 监听且 ssh.socket/ssh 非 active（可能受 ordering cycle 影响未拉起）"; fi

sub "启动耗时"
have systemd-analyze && systemd-analyze time 2>/dev/null || c_na "systemd-analyze"
# [改进] 首启一次性开销提示（host key 生成等会拉高 userspace 耗时）
upsec=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
if [ -n "$upsec" ] && [ "$upsec" -lt 300 ] 2>/dev/null; then c_info "运行<5min：首启一次性开销(host key 生成等)会拉高 userspace 耗时，建议二次启动复测"; fi

# ───────────────────────────── 3. DNS / 解析栈（dns-fix 专项）─────────────────────────────
hdr "3. DNS / 名称解析栈 (验证 dns-fix 根因与 P0 方向)"
sub "/etc/resolv.conf"
ls -l /etc/resolv.conf 2>/dev/null
if [ -L /etc/resolv.conf ]; then
  tgt=$(readlink -f /etc/resolv.conf 2>/dev/null)
  case "$tgt" in
    *stub-resolv.conf) c_ok "resolv.conf -> systemd-resolved stub（收口正确）" ;;
    *) c_info "resolv.conf 软链 -> $tgt" ;;
  esac
else
  c_warn "resolv.conf 是静态文件: [ $(val /etc/resolv.conf | tr '\n' ' ') ]（非 resolved 接管）"
fi
sub "nsswitch hosts 行 (tls 模块 = dns-fix 根因)"
hl=$(grep '^hosts:' /etc/nsswitch.conf 2>/dev/null); echo "  $hl"
if printf '%s' "$hl" | grep -qw tls; then
  c_fail "nsswitch 含 tls 模块 —— getaddrinfo 会被 DoH 超时拖慢（dns-fix 根因）"; CAP[nss_tls]=present
else
  c_ok "nsswitch 无 tls 模块"; CAP[nss_tls]=absent
fi
if dpkg -l 2>/dev/null | grep -qiE '^ii +(nss-tlsd|libnss-tls)'; then
  c_warn "nss-tlsd/libnss-tls 仍安装（建议 purge）"
  systemctl is-active nss-tlsd >/dev/null 2>&1 && c_warn "nss-tlsd 守护进程仍在运行"
fi
sub "systemd-resolved"
echo "  enabled: $(systemctl is-enabled systemd-resolved 2>/dev/null)  active: $(systemctl is-active systemd-resolved 2>/dev/null)"
have resolvectl && timeout 5 resolvectl status 2>/dev/null | sed -n '1,20p'
# [改进] 残留 resolvconf/openresolv 检测（日志 "Failed to set DNS configuration ... network1 not found" 之源）
if dpkg -l 2>/dev/null | grep -qiE '^ii +(resolvconf|openresolv) '; then c_warn "resolvconf/openresolv 仍安装，会与 systemd-resolved 冲突（日志报 network1.service not found）"; fi
sub "解析延迟实测 —— getaddrinfo/NSS 路径 (curl/apt 真实走这条)"
for d in mirrors.tuna.tsinghua.edu.cn www.baidu.com; do
  t4=$(timed getent ahostsv4 "$d")
  ta=$(timed getent ahosts "$d")
  echo "  getent ahostsv4 $d : ${t4}s | ahosts(双栈) : ${ta}s"
  if gt "$t4" 1.0; then c_fail "getaddrinfo 解析 $d 慢 (${t4}s) —— 典型 NSS 层超时"; else c_ok "getaddrinfo $d 正常 (${t4}s)"; fi
done
if have dig; then echo "  dig A baidu (直发,不走NSS): $(timed dig +short A www.baidu.com)s"; fi
if have getent && have dig; then c_info "若 getent 慢而 dig 快 → 问题在 NSS 层（tls/resolv.conf），非上游 DNS"; fi

# ───────────────────────────── 4. 网络连通 ─────────────────────────────
hdr "4. 网络连通"
ip -br addr 2>/dev/null
sub "路由 / 外网"
ip route 2>/dev/null | grep -q '^default' && c_ok "有默认路由" || c_warn "无默认路由"
if ping -c1 -W2 223.5.5.5 >/dev/null 2>&1; then c_ok "可达 223.5.5.5（IP 层联网正常）"; CAP[net]=up; else c_warn "ping 223.5.5.5 失败（可能无外网）"; CAP[net]=down; fi
if have curl; then
  curl -o /dev/null -s --max-time 15 \
    -w '  curl tuna: dns=%{time_namelookup}s connect=%{time_connect}s total=%{time_total}s code=%{http_code}\n' \
    https://mirrors.tuna.tsinghua.edu.cn/ || c_warn "curl 访问失败"
fi
sub "usb0 / NetworkManager"
have nmcli && timeout 5 nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null
if ip link show usb0 >/dev/null 2>&1; then
  us=$(timeout 5 nmcli -t -f DEVICE,STATE device 2>/dev/null | grep '^usb0:')
  echo "  usb0: ${us:-存在}"
  case "$us" in
    *unmanaged*) c_ok "usb0 = unmanaged（符合 P0 预期）" ;;
    "") c_info "usb0 存在（nmcli 不可用，无法判断托管状态）" ;;
    *) c_warn "usb0 被 NM 管理（建议设 unmanaged，避免与 dnsmasq 冲突）" ;;
  esac
else
  c_info "无 usb0 接口（当前未插 USB 或 gadget 未起）"
fi

# ───────────────────────────── 5. IPv6 ─────────────────────────────
hdr "5. IPv6 (内核 CONFIG_IPV6=y，确认在哪一层被关)"
cl=$(grep -o 'ipv6.disable=[01]' /proc/cmdline 2>/dev/null)
a=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
df6=$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null)
sd=$(grep -rsl disable_ipv6 /etc/sysctl.conf /etc/sysctl.d/ 2>/dev/null | tr '\n' ' ')
g6=$(ip -6 addr show scope global 2>/dev/null | grep -c inet6)
echo "  cmdline: ${cl:-无} | sysctl all=$a default=$df6 | sysctl.d 命中: ${sd:-无} | 全局v6地址数: $g6"
if [ "$cl" = "ipv6.disable=1" ]; then
  c_info "IPv6 关闭层 = 内核 cmdline（改它需重打 boot/u-boot，外部侧）"; CAP[ipv6_layer]=cmdline
elif [ "${a:-0}" = 1 ] || [ "${df6:-0}" = 1 ]; then
  c_info "IPv6 关闭层 = sysctl（${sd:-运行时}）—— 可在镜像内恢复"; CAP[ipv6_layer]=sysctl
elif [ "${g6:-0}" -gt 0 ] 2>/dev/null; then
  c_ok "IPv6 已启用（有全局地址）"; CAP[ipv6_layer]=enabled
else
  c_info "IPv6 未显式禁用但无全局地址（可能上游无 RA/v6）"; CAP[ipv6_layer]=none_noaddr
fi

# ───────────────────────────── 6. 存储 ─────────────────────────────
hdr "6. 存储 (TRIM / noatime / /boot 余量)"
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT 2>/dev/null
sub "挂载选项"
echo "  / :    $(findmnt -no SOURCE,FSTYPE,OPTIONS / 2>/dev/null)"
echo "  /boot: $(findmnt -no SOURCE,FSTYPE,OPTIONS /boot 2>/dev/null)"
findmnt -no OPTIONS / 2>/dev/null | grep -qw noatime && c_ok "/ 已启用 noatime" || c_info "/ 未用 noatime（P0/P1 重建镜像后生效）"
sub "TRIM / discard 支持"
lsblk -D -o NAME,DISC-GRAN,DISC-MAX,MOUNTPOINT 2>/dev/null
if lsblk -D -bn -o DISC-MAX 2>/dev/null | awk '{if($1+0>0)f=1} END{exit !f}'; then
  c_ok "块层支持 discard（fstrim 可生效）"; CAP[trim]=yes
else
  c_warn "未检测到 discard 支持（DISC-MAX 全为 0）"; CAP[trim]=no
fi
echo "  fstrim.timer: $(systemctl is-enabled fstrim.timer 2>/dev/null)/$(systemctl is-active fstrim.timer 2>/dev/null)"
echo "  （如需实测可手动：sudo fstrim -v / ）"
sub "容量"
df -h / /boot 2>/dev/null
bfree=$(df -m --output=avail /boot 2>/dev/null | tail -1 | tr -cd '0-9')
echo "  /boot 可用: ${bfree:-?} MB（同步钩子需容两套 kernel+initramfs）"
# [改进] 核对 boot 镜像同步钩子（设备端内核更新能否生效的关键不变量）
sub "boot 镜像同步钩子 (设备端更新内核能否生效)"
for f in /boot/linux.efi /boot/initramfs; do [ -e "$f" ] && printf '  [OK]  %s (%s bytes)\n' "$f" "$(stat -c%s "$f" 2>/dev/null)" || printf '  [缺]  %s\n' "$f"; done
hk=0; for d in /etc/kernel/postinst.d /etc/initramfs/post-update.d; do [ -e "$d/zz-sync-uboot-images" ] && hk=$((hk+1)); done
[ "$hk" -eq 2 ] && c_ok "内核/initramfs 同步钩子已安装 (2/2)" || c_warn "同步钩子不全 ($hk/2) → 设备端更新内核可能静默不生效"

# ───────────────────────────── 7. 内存 / swap / OOM ─────────────────────────────
hdr "7. 内存 / zram / OOM 兜底"
free -h 2>/dev/null
sub "zram / swap"
have zramctl && zramctl 2>/dev/null
swapon --show 2>/dev/null
echo "  vm.swappiness=$(sysctl -n vm.swappiness 2>/dev/null)  vm.page-cluster=$(sysctl -n vm.page-cluster 2>/dev/null)"
swapon --show 2>/dev/null | grep -q zram && c_ok "zram swap 已启用" || c_warn "未检测到 zram swap"
sub "OOM 保护"
if systemctl is-active earlyoom >/dev/null 2>&1; then c_ok "earlyoom 运行中"; CAP[oom]=earlyoom
elif systemctl is-active systemd-oomd >/dev/null 2>&1; then c_ok "systemd-oomd 运行中"; CAP[oom]=oomd
else c_warn "无 OOM 保护守护（内存压力下可能整机硬卡死）"; CAP[oom]=none; fi
if [ -r /proc/pressure/memory ]; then c_ok "PSI 可用（systemd-oomd 可选）"; CAP[psi]=yes; echo "  $(val /proc/pressure/memory)"
else c_info "PSI 不可用（用 earlyoom）"; CAP[psi]=no; fi

# ───────────────────────────── 8. 电源 / 热 / 电池 ─────────────────────────────
hdr "8. 电源 / 热 / 电池"
echo "  /sys/power/state : $(val /sys/power/state)"
echo "  mem_sleep        : $(val /sys/power/mem_sleep)"
echo "  cpufreq governor : $(val /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
case "$(val /sys/power/mem_sleep)" in
  *'[deep]'*) c_ok "支持 deep（真正挂起省电）" ;;
  *'[s2idle]'*) c_info "仅 s2idle（mainline 常态；深睡眠未必可用）" ;;
esac
sub "thermal zones（当前温度）"
hot=0
for z in /sys/class/thermal/thermal_zone*; do
  [ -e "$z/temp" ] || continue
  t=$(val "$z/temp"); ty=$(val "$z/type")
  [ -n "$t" ] || continue
  c=$(awk -v x="$t" 'BEGIN{printf "%.1f", x/1000}')
  printf '  %-26s %s C\n' "$ty" "$c"
  gt "$c" 80 && hot=1
done
[ "$hot" = 1 ] && c_warn "有热区 >80°C（注意散热/负载）" || c_ok "温度正常"
sub "电池"
for b in /sys/class/power_supply/*; do
  [ -e "$b/capacity" ] || continue
  echo "  $(basename "$b"): $(val "$b/capacity")% status=$(val "$b/status") health=$(val "$b/health")"
done

# ───────────────────────────── 9. Watchdog ─────────────────────────────
hdr "9. Watchdog (QCOM_WDT；不仅看存在，还要确认 systemd 真的 arm 上了)"
if ls /dev/watchdog* >/dev/null 2>&1; then
  c_ok "/dev/watchdog 存在"; CAP[watchdog]=present
  wd=$(ls -d /sys/class/watchdog/watchdog* 2>/dev/null | head -1)
  maxt=$(num "$(val "$wd/max_timeout")"); curt=$(val "$wd/timeout"); wst=$(val "$wd/state")
  echo "  $(basename "${wd:-watchdog0}"): identity=$(val "$wd/identity") max_timeout=${maxt:-?}s timeout=${curt:-?}s state=${wst:-?}"
else
  c_info "无 /dev/watchdog（QCOM_WDT 可能未 probe）→ 暂不启用自愈"; CAP[watchdog]=no; maxt=""
fi
rwd=$(systemctl show -p RuntimeWatchdogUSec --value 2>/dev/null)
echo "  systemd RuntimeWatchdogUSec=${rwd:-?}"
# [真相核对] 判定 armed 必须以 PID1 的 boot 日志为准，不能看 sysfs/RuntimeWatchdogUSec：
#   - qcom_wdt 不导出 /sys/class/watchdog/watchdog0/{timeout,max_timeout,state}，故 $curt/$maxt 恒空；
#   - RuntimeWatchdogSec=default 会让 RuntimeWatchdogUSec 显示 infinity（哨兵≠关闭），仍以内核默认超时 arm。
#   权威信号：systemd 启动时记录 "Watchdog running with a (hardware) timeout of <N>s"。
if [ "${CAP[watchdog]}" = present ]; then
  rwd_s=$(printf '%s' "$rwd" | awk '{v=$0; if(v~/min/){sub(/min.*/,"",v);print v*60} else if(v~/s/){sub(/s.*/,"",v);print v+0} else print 0}')
  wdlog=$(timeout 10 journalctl -b --no-pager 2>/dev/null | grep -iE 'Watchdog running with a .*timeout of|Failed to set watchdog hardware timeout')
  wdrun=$(printf '%s\n' "$wdlog" | grep -iE 'Watchdog running with a .*timeout of' | tail -1)
  wderr=$(printf '%s\n' "$wdlog" | grep -i 'Failed to set watchdog hardware timeout' | tail -1)
  if [ -n "$wdrun" ]; then
    wto=$(printf '%s' "$wdrun" | grep -oE 'timeout of [0-9]+' | grep -oE '[0-9]+')
    c_ok "看门狗已 arm（systemd 硬件超时 ${wto:-?}s；default 模式下 RuntimeWatchdogUSec=infinity 属正常）→ 自愈生效"
    CAP[watchdog]=armed
  elif [ -n "$wderr" ]; then
    c_fail "systemd 未能 arm 看门狗（自愈实际未生效）：${wderr#*]: }；RuntimeWatchdogSec 需 ≤ 硬件 max_timeout(${maxt:-?}s)"
    CAP[watchdog]=present_unarmed
  elif [ -n "$maxt" ] && [ "${maxt:-0}" -gt 0 ] 2>/dev/null && gt "${rwd_s:-0}" "$maxt"; then
    c_fail "RuntimeWatchdogSec(${rwd_s}s) > 硬件 max_timeout(${maxt}s) → 内核会拒绝(EINVAL)，看门狗未 arm"
    CAP[watchdog]=present_unarmed
  elif [ -n "$curt" ] && [ "${curt:-0}" != 0 ] 2>/dev/null; then
    c_ok "看门狗已 arm（当前 timeout=${curt}s）→ 自愈生效"; CAP[watchdog]=armed
  else
    c_info "看门狗存在但无法从 journal 确认（本脚本需以 root 运行才能读系统日志）；RuntimeWatchdogSec 也可能为 0/off"
  fi
fi

# ───────────────────────────── 10. 设备身份唯一性 ─────────────────────────────
hdr "10. 设备身份唯一性 (machine-id / SSH host key 是否被烤进镜像)"
mid=$(val /etc/machine-id)
echo "  /etc/machine-id: [${mid}] (长度 ${#mid})"
# [改进] 运行态 machine-id 必然已填充（systemd 首启生成），单看实机【无法】判定是否烤死，
#        旧逻辑据此报"老镜像"属误判。真正可判定：① 镜像内该文件是否为空 ② 跨设备比对。
if [ -z "$mid" ]; then
  c_ok "machine-id 为空（未启动的镜像态；首启将生成）"
else
  c_info "machine-id 已填充：运行态必然如此，不能据此判定烤死（需查镜像内是否为空 / 跨设备比对指纹）"
fi
ls -l /var/lib/dbus/machine-id 2>/dev/null
# [改进] 改为核对"首启重生成机制"是否就位，比看 machine-id 内容可靠
regen=$(systemctl is-enabled regenerate-ssh-host-keys.service 2>/dev/null)
echo "  regenerate-ssh-host-keys.service: ${regen:-缺失}"
[ "$regen" = enabled ] && c_ok "SSH host key 首启重生成机制已启用" || c_warn "未启用首启重生成（各机可能共用同一套 host key）"
sub "SSH host key 指纹与生成时间 (mtime≈本次启动日 → 已按机重生成的佐证)"
for k in /etc/ssh/ssh_host_*_key.pub; do [ -e "$k" ] && ssh-keygen -lf "$k" 2>/dev/null; done
ls -l --time-style=+%F /etc/ssh/ssh_host_*_key 2>/dev/null | awk '{print "  "$6"  "$NF}'
btime=$(date -d "$(uptime -s 2>/dev/null)" +%F 2>/dev/null)
kdate=$(ls -l --time-style=+%F /etc/ssh/ssh_host_ed25519_key 2>/dev/null | awk '{print $6}')
echo "  本次启动日期=$btime  host key 日期=$kdate"
if [ -n "$kdate" ] && [ "$kdate" = "$btime" ]; then c_ok "host key 日期=启动日期 → 首启重生成在工作（佐证）"
else c_info "host key 日期≠启动日期（已运行多日或非首启；不代表有问题）"; fi
c_info "确证唯一性仍需：两台设备比对指纹，或检查镜像内 /etc/ssh 是否已清空"

# ───────────────────────────── 11. 关键硬件子系统 ─────────────────────────────
hdr "11. 关键硬件子系统 (raphael 可用性)"
sub "remoteproc（sm8150 DSP/modem 固件加载，关键）"
any=0
for r in /sys/class/remoteproc/*; do
  [ -e "$r/state" ] || continue; any=1
  nm=$(val "$r/name"); stt=$(val "$r/state")
  printf '  %-22s %s\n' "${nm:-$(basename "$r")}" "$stt"
  [ "$stt" = running ] || c_warn "remoteproc ${nm:-$(basename "$r")} 状态=$stt（非 running）"
done
[ "$any" = 1 ] && c_ok "remoteproc 已枚举" || c_info "无 remoteproc 节点"
sub "高通服务"
for s in rmtfs pd-mapper tqftpserv; do
  systemctl is-active "$s" >/dev/null 2>&1 && c_ok "$s 运行中" || c_warn "$s 未运行/未安装"
done
sub "WiFi"
lsmod 2>/dev/null | grep -q ath10k && c_ok "ath10k 已加载" || c_warn "ath10k 未加载"
have iw && iw dev 2>/dev/null | awk '/Interface|type|ssid/{print "  "$0}'
for n in /sys/class/net/wl*; do [ -e "$n" ] || continue; d=$(basename "$n"); echo "  $d power_save: $(iw dev "$d" get power_save 2>/dev/null | awk '{print $NF}')"; done
sub "蓝牙"
# [改进] 先看内核/驱动侧（与 CLI 工具是否安装无关）：qca/crbtfw21.tlv 缺失会导致 hci 起不来
hci=$(ls /sys/class/bluetooth/ 2>/dev/null | tr '\n' ' ')
echo "  /sys/class/bluetooth: ${hci:-（无 hci 设备）}"
[ -n "$hci" ] && c_ok "蓝牙控制器已注册 ($hci)" || c_warn "无蓝牙 hci 设备（常因 qca/crbtfw21.tlv 固件缺失）"
have rfkill && rfkill list 2>/dev/null | grep -iA1 bluetooth | sed 's/^/  /'
if have hciconfig; then timeout 5 hciconfig 2>/dev/null | head -3
elif have bluetoothctl; then timeout 5 bluetoothctl list 2>/dev/null
else c_na "蓝牙 CLI 工具"; fi
sub "音频"
# [改进] 先看声卡是否注册（与 alsa-utils 是否安装无关）：q6asm-dai probe 失败会导致无声卡
echo "  /proc/asound/cards:"; sed 's/^/    /' /proc/asound/cards 2>/dev/null || echo "    (无)"
if grep -qE '^[[:space:]]*[0-9]+[[:space:]]*\[' /proc/asound/cards 2>/dev/null; then c_ok "已注册声卡"; else c_warn "无声卡注册（常因 q6asm-dai 探测失败 / ADSP 音频通路未起）"; fi
have aplay && aplay -l 2>/dev/null | grep -i card | sed 's/^/  /'
have pactl && timeout 5 pactl info 2>/dev/null | grep -iE 'Server|Default Sink' | sed 's/^/  /'
sub "触摸屏 / 输入"
grep -iE 'Name=.*(touch|fts|goodix|synaptics|nvt|focal)' /proc/bus/input/devices 2>/dev/null | sed 's/^/  /' || c_info "input 设备里未匹配到触摸关键字"
sub "GPU / DRM"
if ls /dev/dri/* >/dev/null 2>&1; then c_ok "DRM 节点存在: $(ls /dev/dri 2>/dev/null | tr '\n' ' ')"; else c_warn "无 /dev/dri（GPU 可能未起）"; fi
for c in /sys/class/drm/card[0-9]; do [ -e "$c/device/uevent" ] && grep -i driver "$c/device/uevent" 2>/dev/null | sed "s#^#  $(basename "$c") #"; done
sub "USB gadget (NCM)"
ls /sys/kernel/config/usb_gadget/ >/dev/null 2>&1 && c_ok "configfs gadget 已配置: $(ls /sys/kernel/config/usb_gadget/ 2>/dev/null | tr '\n' ' ')" || c_info "无 configfs gadget（可能未插 USB）"

sub "固件补齐核对 (09 backfill 目标是否落地；缺失=构建期 gitlab 拉取失败)"
fwmiss=0
for fw in qcom/a630_sqe.fw qcom/a640_gmu.bin qcom/sm8150/a640_zap.mbn qca/crbtfw21.tlv qca/crnv21.bin; do
  if [ -e "/lib/firmware/$fw" ]; then printf '  [OK]  %s (%s bytes)\n' "$fw" "$(stat -c%s "/lib/firmware/$fw" 2>/dev/null)"
  else printf '  [缺]  %s\n' "$fw"; fwmiss=$((fwmiss+1)); fi
done
if [ "$fwmiss" -gt 0 ]; then c_warn "$fwmiss 个 backfill 固件缺失 → GPU(a630_sqe)/蓝牙(crbtfw21) 等受影响；构建期需换可达镜像或 vendoring"; CAP[fw_backfill]=missing
else c_ok "backfill 固件齐全"; CAP[fw_backfill]=ok; fi

# ───────────────────────────── 12. 日志中的错误 ─────────────────────────────
hdr "12. 日志错误 (本次启动)"
if have journalctl; then
  errc=$(timeout 20 journalctl -p err -b --no-pager 2>/dev/null | grep -c .)
  echo "  err 级日志行数: ${errc:-0}"
  if [ "${errc:-0}" -gt 50 ] 2>/dev/null; then c_warn "err 日志较多（${errc}），样本如下"; else c_ok "err 日志量正常（${errc:-0}）"; fi
  timeout 20 journalctl -p err -b --no-pager 2>/dev/null | tail -n 20 | sed 's/^/  /'
else c_na "journalctl"; fi
sub "固件加载失败 (dmesg)"
timeout 10 dmesg 2>/dev/null | grep -iE 'firmware|failed to load|direct firmware|rproc|adsp|cdsp' | grep -iE 'fail|error|timeout' | tail -n 15 | sed 's/^/  /' || c_na "dmesg（需 root）"

# ───────────────────────────── 13. 时间同步 / NTP（A2）─────────────────────────────
hdr "13. 时间同步 / NTP (时钟错乱会伪装成 DNS/TLS/apt 故障)"
nsync=""; tsd=""
if have timedatectl; then
  td=$(timedatectl show 2>/dev/null)
  nsync=$(printf '%s\n' "$td" | sed -n 's/^NTPSynchronized=//p')
  echo "  NTP=$(printf '%s\n' "$td" | sed -n 's/^NTP=//p')  NTPSynchronized=$nsync  Timezone=$(printf '%s\n' "$td" | sed -n 's/^Timezone=//p')  LocalRTC=$(printf '%s\n' "$td" | sed -n 's/^LocalRTC=//p')"
else
  echo "  timedatectl 不可用"
fi
for s in systemd-timesyncd chrony chronyd ntp ntpsec; do
  systemctl is-active "$s" >/dev/null 2>&1 && { echo "  时间同步服务: $s = active"; tsd=$s; break; }
done
[ -z "$tsd" ] && echo "  时间同步服务: 无 active 守护"
yr=$(date +%Y 2>/dev/null)
echo "  当前系统时间: $(date '+%F %T %Z')"
skew=""
if have curl && [ "${CAP[net]}" = up ]; then
  rdate=$(curl -sI --max-time 8 https://mirrors.tuna.tsinghua.edu.cn/ 2>/dev/null | tr -d '\r' | sed -n 's/^[Dd]ate: //p' | head -1)
  if [ -n "$rdate" ]; then
    rs=$(date -d "$rdate" +%s 2>/dev/null); locs=$(date +%s)
    [ -n "$rs" ] && skew=$(awk -v a="$rs" -v b="$locs" 'BEGIN{d=a-b; if(d<0)d=-d; print d}')
    echo "  HTTP Date 校时: 远端=[$rdate]  本地偏差≈${skew:-?}s"
  fi
fi
if [ "$nsync" = yes ]; then
  c_ok "时钟已与 NTP 同步"; CAP[timesync]=synced
elif [ -n "$yr" ] && [ "$yr" -lt 2024 ] 2>/dev/null; then
  c_fail "系统时钟年份=$yr 明显错乱（设备无 RTC 电池常见）→ TLS 证书校验必败、apt/curl HTTPS 全崩"; CAP[timesync]=clock_wrong
elif [ -n "$skew" ] && [ "$skew" -gt 90 ] 2>/dev/null; then
  c_fail "时钟与网络相差 ${skew}s（>90s）→ TLS/证书校验可能失败"; CAP[timesync]=skewed
elif [ "$nsync" = no ]; then
  c_warn "NTP 未同步（${tsd:-无同步服务}）—— 联网后应自动校正；纯离线场景需手动 timedatectl set-time"; CAP[timesync]=unsynced
else
  c_info "无法判定时间同步状态"; CAP[timesync]=unknown
fi

# ───────────────────────────── 14. 包状态 / apt-mark hold（A3，验不变量）─────────────────────────────
hdr "14. 包状态 / apt-mark hold (内核被 unattended-upgrade 换掉=变砖)"
if have apt-mark; then
  holds=$(apt-mark showhold 2>/dev/null)
  echo "  当前 hold 列表:"; printf '%s\n' "${holds:-（空）}" | sed 's/^/    /'
  kpkgs=$(dpkg -l 2>/dev/null | awk '/^ii/ && $2 ~ /^linux-(image|headers)-[0-9]/ {print $2}')
  echo "  已安装内核包: ${kpkgs:-（无）}"
  miss=0
  for p in $kpkgs; do printf '%s\n' "$holds" | grep -qxF "$p" || { c_fail "内核包未 hold: $p（apt / unattended-upgrades 可能替换 → 变砖）"; miss=1; }; done
  if dpkg -l firmware-xiaomi-raphael >/dev/null 2>&1; then
    printf '%s\n' "$holds" | grep -qxF firmware-xiaomi-raphael || { c_warn "固件包未 hold: firmware-xiaomi-raphael"; miss=1; }
  fi
  if [ "$miss" = 0 ] && [ -n "$kpkgs" ]; then c_ok "内核/固件均已 apt-mark hold"; CAP[apt_hold]=ok; else CAP[apt_hold]=incomplete; fi
else
  c_na "apt-mark"; CAP[apt_hold]=unknown
fi
sub "包数据库一致性 (dpkg -C)"
if have dpkg; then
  broken=$(dpkg -C 2>/dev/null | grep -v '^[[:space:]]*$' | head -10)
  if [ -n "$broken" ]; then c_warn "dpkg -C 报告半装/未配置包:"; printf '%s\n' "$broken" | sed 's/^/    /'; else c_ok "dpkg 数据库一致（无半装包）"; fi
fi
sub "unattended-upgrades 内核排除"
uf=/etc/apt/apt.conf.d/50unattended-upgrades
if [ -r "$uf" ]; then
  grep -qiE 'linux-image|linux-generic|"linux-"|Package-Blacklist' "$uf" 2>/dev/null && c_info "unattended-upgrades 含内核/黑名单相关条目（请确认在 Package-Blacklist 段内）" || c_info "unattended-upgrades 未显式排除内核（已 apt-mark hold 即可兜底）"
else
  c_info "无 50unattended-upgrades（未启用自动升级 / 仅 hold 兜底）"
fi

# ───────────────────────────── 15. 音频链路根因（A1，深化）─────────────────────────────
hdr "15. 音频链路根因定位 (QDSP6/q6 probe 链 → 区分 DTB 缺陷 vs rootfs 可修)"
has_card=0; grep -qE '^[[:space:]]*[0-9]+[[:space:]]*\[' /proc/asound/cards 2>/dev/null && has_card=1
echo "  /proc/asound/cards:"; sed 's/^/    /' /proc/asound/cards 2>/dev/null
sub "q6/ASoC 模块加载"
lsmod 2>/dev/null | grep -iE 'q6|apr|snd_soc|gpr' | sed 's/^/  /' || echo "  （无 q6/snd_soc 模块；可能 builtin）"
sub "q6 平台驱动绑定情况 (bound device = probe 成功)"
shopt -s nullglob 2>/dev/null
for drv in /sys/bus/platform/drivers/*q6* /sys/bus/platform/drivers/*apr* /sys/bus/platform/drivers/*gpr*; do
  [ -d "$drv" ] || continue
  bound=$(for e in "$drv"/*; do b=$(basename "$e"); case "$b" in bind|unbind|uevent|module) ;; *) [ -L "$e" ] && echo "$b";; esac; done | tr '\n' ' ')
  printf '  %-26s bound=[%s]\n' "$(basename "$drv")" "${bound:-无}"
done
shopt -u nullglob 2>/dev/null
sub "DT 音频节点 (machine driver / DAI)"
snd_node=$(ls -d /proc/device-tree/sound* /proc/device-tree/*/sound* 2>/dev/null | head -1)
if [ -n "$snd_node" ]; then echo "  DT sound 节点: $snd_node (compatible=$(tr -d '\0' < "$snd_node/compatible" 2>/dev/null))"; else echo "  DT 无顶层 sound 节点"; fi
dais_node=$(find /proc/device-tree -maxdepth 6 -type d -name 'dais' 2>/dev/null | head -1)
if [ -n "$dais_node" ]; then
  daichild=$(find "$dais_node" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
  echo "  DT dais 节点: $dais_node  子 DAI 数=$daichild"
fi
sub "dmesg q6/snd probe 链"
admsg=$(timeout 10 dmesg 2>/dev/null | grep -iE 'q6asm|q6afe|q6routing|q6adm|q6core|apr|snd[-_]soc|sndcard|gpr' | tail -n 15)
if [ -n "$admsg" ]; then printf '%s\n' "$admsg" | sed 's/^/  /'; else echo "  （无相关 dmesg；可能需 root）"; fi
if [ "$has_card" = 1 ]; then
  c_ok "已注册声卡 → 音频通路可用"; CAP[audio]=ok
elif printf '%s' "$admsg" | grep -qiE 'No dais found in DT|dais.*-22|q6asm-dai.*failed'; then
  c_warn "无声卡：DTB 的 APR dais 节点缺 DAI 子节点（q6asm-dai probe -22）→ DTB/上游缺陷，rootfs 无解，需修 DTB 或换内核"; CAP[audio]=dtb_missing_dais
elif [ -z "$snd_node" ]; then
  c_warn "无声卡：DT 无 sound machine 节点 → 即使 DAI 正常也不会建卡（DTB 缺陷）"; CAP[audio]=no_machine_node
else
  c_warn "无声卡：q6 模块/UCM 可能缺失（rootfs 侧或可补）—— 见上方 probe 链定位"; CAP[audio]=module_or_ucm
fi

# ───────────────────────────── 16. 传感器 / 自动旋转（B2）─────────────────────────────
hdr "16. 传感器 / 自动旋转 / 贴脸熄屏 (IIO + iio-sensor-proxy)"
acc=0; als=0; prox=0; magn=0; gyro=0
shopt -s nullglob 2>/dev/null
for d in /sys/bus/iio/devices/iio:device*; do
  [ -e "$d/name" ] || continue
  printf '  IIO %s: %s\n' "$(basename "$d")" "$(val "$d/name")"
  ls "$d" 2>/dev/null | grep -q accel && acc=1
  ls "$d" 2>/dev/null | grep -q illuminance && als=1
  ls "$d" 2>/dev/null | grep -qiE 'proximity|distance' && prox=1
  ls "$d" 2>/dev/null | grep -q magn && magn=1
  ls "$d" 2>/dev/null | grep -q anglvel && gyro=1
done
shopt -u nullglob 2>/dev/null
[ "$acc$als$prox$magn$gyro" = "00000" ] && echo "  （/sys/bus/iio 下无传感器设备）"
echo "  传感器汇总: accel=$acc als=$als proximity=$prox magn=$magn gyro=$gyro"
isp="未安装"
if have monitor-sensor || systemctl list-unit-files 2>/dev/null | grep -q iio-sensor-proxy; then
  isp="$(systemctl is-active iio-sensor-proxy 2>/dev/null || echo inactive)"
fi
echo "  iio-sensor-proxy: $isp"
if [ "$acc" = 1 ] && { [ "$isp" = active ] || have monitor-sensor; }; then
  c_ok "加速度计 + iio-sensor-proxy 就绪 → phosh 自动旋转可用"; CAP[autorotate]=yes
elif [ "$acc" = 1 ]; then
  c_warn "有加速度计但缺 iio-sensor-proxy → 自动旋转不可用（装 iio-sensor-proxy 即可）"; CAP[autorotate]=no_proxy
else
  c_info "无加速度计 IIO 设备 → 自动旋转不可用（多为 DTB 未描述传感器）"; CAP[autorotate]=no_accel
fi
[ "$prox" = 1 ] && c_ok "有距离传感器 → 通话贴脸熄屏可用" || c_info "无距离传感器 → 贴脸熄屏不可用"

# ───────────────────────────── 17. 调制解调器（B3）─────────────────────────────
hdr "17. 调制解调器 (remoteproc running ≠ 可用；需 ModemManager 能看到 modem)"
mst=$(cat /sys/class/remoteproc/*/state 2>/dev/null | tr '\n' ' ')
echo "  remoteproc 各核状态: ${mst:-?}"
sub "ModemManager"
mma=$(systemctl is-active ModemManager 2>/dev/null); echo "  ModemManager 服务: ${mma:-未安装}"
nmod=0
if have mmcli; then
  ml=$(timeout 8 mmcli -L 2>/dev/null)
  if [ -n "$ml" ]; then printf '%s\n' "$ml" | sed 's/^/  /'; else echo "  （mmcli -L 无输出）"; fi
  nmod=$(printf '%s' "$ml" | grep -ciE '/Modem/[0-9]')
else
  c_na "mmcli (ModemManager CLI)"
fi
sub "QMI/MBIM/qrtr 节点"
ls /dev/wwan* /dev/cdc-wdm* 2>/dev/null | sed 's/^/  /' || echo "  无 /dev/wwan|cdc-wdm 节点"
have qrtr-lookup && timeout 5 qrtr-lookup 2>/dev/null | head -8 | sed 's/^/  /'
if [ "${nmod:-0}" -ge 1 ] 2>/dev/null; then
  c_ok "ModemManager 已识别到 modem → 移动数据/短信可配"; CAP[modem]=usable
  timeout 8 mmcli -m 0 2>/dev/null | grep -iE 'state|signal|operator|sim|access tech' | sed 's/^/    /'
elif printf '%s' "$mst" | grep -qw running; then
  c_warn "modem remoteproc running 但 MM 看不到 modem → 当前不可用（sm8150 mainline 常态：需 qrtr/rmtfs 配合，通话/VoLTE 多不支持）"; CAP[modem]=rproc_only
else
  c_info "无 modem remoteproc / ModemManager"; CAP[modem]=absent
fi

# ───────────────────────────── 18. 挂起/恢复质量（C1，非侵入）─────────────────────────────
hdr "18. 挂起 / 恢复质量 (非侵入：不真正挂起；真测见末尾 rtcwake 提示)"
echo "  mem_sleep: $(val /sys/power/mem_sleep)   wakeup_count: $(val /sys/power/wakeup_count)"
sub "休眠抑制锁 (谁在阻止 sleep/idle)"
if have systemd-inhibit; then timeout 5 systemd-inhibit --list --no-pager 2>/dev/null | sed 's/^/  /'; else c_na "systemd-inhibit"; fi
sub "唤醒源 (debugfs wakeup_sources，需 root+debugfs)"
if [ -r /sys/kernel/debug/wakeup_sources ]; then
  awk 'NR==1{print; next} (($3+0)>0 || ($4+0)>0){print}' /sys/kernel/debug/wakeup_sources 2>/dev/null | head -15 | sed 's/^/  /'
else
  c_info "无法读 /sys/kernel/debug/wakeup_sources（需 root 且挂载 debugfs）"
fi
sub "历史挂起/恢复事件 (journal)"
sus=$(timeout 15 journalctl -b --no-pager 2>/dev/null | grep -iE 'PM: suspend|PM: resume|suspend entry|suspend exit|Freezing user space|Restarting tasks' | tail -8)
if [ -n "$sus" ]; then
  printf '%s\n' "$sus" | sed 's/^/  /'
  printf '%s' "$sus" | grep -qiE 'abort|fail|error' && c_warn "历史挂起/恢复中出现 abort/fail（见上）" || c_info "本次启动有挂起/恢复记录（未见明显失败）"
else
  c_info "本次启动无挂起/恢复记录（未休眠过）"
fi
c_info "真测可手动（会真挂起，慎用）：sudo rtcwake -m freeze -s 15  然后查 journal 的 resume 段"
CAP[suspend]="$(val /sys/power/mem_sleep | grep -oE '\[[a-z0-9]+\]' | tr -d '[]')"

# ───────────────────────────── 19. 文件系统健康 & 扩容（C2）─────────────────────────────
hdr "19. 文件系统健康 & 自动扩容核对"
rootsrc=$(findmnt -no SOURCE / 2>/dev/null)
echo "  / 源设备: ${rootsrc:-?}"
if have dumpe2fs && [ -n "$rootsrc" ]; then
  de=$(timeout 10 dumpe2fs -h "$rootsrc" 2>/dev/null)
  fst=$(printf '%s\n' "$de" | sed -n 's/^Filesystem state: *//p')
  echo "  Filesystem state: ${fst:-?(需 root)}"
  printf '%s\n' "$de" | grep -iE 'Mount count|Maximum mount count|Lifetime writes|FS Error count|First error|Last error' | sed 's/^/  /'
  case "$fst" in
    *clean*) c_ok "ext4 状态 clean"; CAP[fs_health]=clean ;;
    "") c_info "无法读取 ext4 superblock（需 root）"; CAP[fs_health]=unknown ;;
    *) c_warn "ext4 状态非 clean: $fst（可能有未决错误）"; CAP[fs_health]=not_clean ;;
  esac
  ec=$(printf '%s\n' "$de" | sed -n 's/^FS Error count: *//p' | tr -cd '0-9')
  [ -n "$ec" ] && [ "$ec" -gt 0 ] 2>/dev/null && c_warn "ext4 记录到 $ec 次文件系统错误（追因看 dmesg）"
fi
sub "自动扩容核对 (fs 大小应≈分区大小)"
if [ -n "$rootsrc" ]; then
  psz=$(blockdev --getsize64 "$rootsrc" 2>/dev/null)
  fsz=$(df -B1 --output=size / 2>/dev/null | tail -1 | tr -cd '0-9')
  if [ -n "$psz" ] && [ -n "$fsz" ] && [ "$psz" -gt 0 ] 2>/dev/null; then
    pct=$(awk -v f="$fsz" -v p="$psz" 'BEGIN{printf "%d", f*100/p}')
    echo "  分区=$(awk -v x="$psz" 'BEGIN{printf "%.1f", x/1073741824}')G  文件系统=$(awk -v x="$fsz" 'BEGIN{printf "%.1f", x/1073741824}')G  占比=${pct}%"
    if [ "$pct" -ge 90 ] 2>/dev/null; then c_ok "rootfs 已扩容填满分区 (${pct}%)"; CAP[fs_resize]=ok; else c_warn "rootfs 仅占分区 ${pct}% → 首启扩容可能未完成，浪费空间"; CAP[fs_resize]=incomplete; fi
  else
    c_info "无法取得分区/文件系统字节数（blockdev 需权限）"; CAP[fs_resize]=unknown
  fi
fi

# ───────────────────────────── 20. 严重事件历史（C4，深化日志）─────────────────────────────
hdr "20. 严重事件历史 (沉默的间歇故障：OOM / rproc 崩溃 / oops / 热降频)"
ja=$(timeout 20 journalctl -b --no-pager 2>/dev/null)
report_cat() { # $1=label $2=pattern
  local hits n
  n=$(printf '%s\n' "$ja" | grep -ciE "$2")
  if [ "${n:-0}" -gt 0 ] 2>/dev/null; then
    c_warn "$1：${n} 次"; printf '%s\n' "$ja" | grep -iE "$2" | tail -6 | sed 's/^/    /'
  else
    c_ok "$1：无"
  fi
}
report_cat "OOM 杀进程"          'Out of memory|oom-kill|Killed process|earlyoom.*(SIGKILL|sending)'
report_cat "remoteproc 崩溃/恢复" 'remoteproc.*(crash|fatal|recover)|q6v5.*(fatal|crash)|rproc.*crash'
report_cat "内核 oops/异常"      'Internal error|Call trace|kernel NULL pointer|BUG:|Unable to handle|segfault'
report_cat "热降频/过温"         'thermal.*(throttl|trip point)|cpu[0-9].*throttl|critical temperature'

# ───────────────────────────── 小结 ─────────────────────────────
hdr "分析报告 · 小结"
printf '\n>> 问题 ISSUE (%s):\n' "${#F_FAIL[@]}"; for x in "${F_FAIL[@]}"; do echo "   - $x"; done
printf '\n>> 警告 WARN (%s):\n'  "${#F_WARN[@]}"; for x in "${F_WARN[@]}"; do echo "   - $x"; done
printf '\n>> 提示 INFO (%s):\n'  "${#F_INFO[@]}"; for x in "${F_INFO[@]}"; do echo "   - $x"; done

hdr "优化能力矩阵 (供下一步实际优化决策)"
printf '  %-18s : %s\n' "nss-tls 根因"   "${CAP[nss_tls]:-?}（present=需清理）"
printf '  %-18s : %s\n' "OOM 保护"        "${CAP[oom]:-?}"
printf '  %-18s : %s\n' "PSI(oomd前提)"   "${CAP[psi]:-?}"
printf '  %-18s : %s\n' "TRIM/discard"    "${CAP[trim]:-?}"
printf '  %-18s : %s\n' "watchdog"        "${CAP[watchdog]:-?}（armed=自愈生效 / present_unarmed=超硬件上限未生效）"
printf '  %-18s : %s\n' "固件补齐"        "${CAP[fw_backfill]:-?}（missing=GPU/蓝牙固件未落地）"
printf '  %-18s : %s\n' "IPv6 关闭层"     "${CAP[ipv6_layer]:-?}"
printf '  %-18s : %s\n' "外网连通"        "${CAP[net]:-?}"
printf '  %-18s : %s\n' "时间同步"        "${CAP[timesync]:-?}（synced=好 / clock_wrong/skewed=会崩 TLS）"
printf '  %-18s : %s\n' "apt-mark hold"   "${CAP[apt_hold]:-?}（ok=内核已锁，防 unattended 换核变砖）"
printf '  %-18s : %s\n' "音频"            "${CAP[audio]:-?}（dtb_missing_dais=DTB缺陷 / ok=可用）"
printf '  %-18s : %s\n' "自动旋转"        "${CAP[autorotate]:-?}（yes=accel+proxy 就绪）"
printf '  %-18s : %s\n' "调制解调器"      "${CAP[modem]:-?}（usable / rproc_only=起了但用不了）"
printf '  %-18s : %s\n' "挂起模式"        "${CAP[suspend]:-?}（s2idle=浅睡 / deep=真挂起）"
printf '  %-18s : %s\n' "文件系统"        "${CAP[fs_health]:-?}/${CAP[fs_resize]:-?}（clean/ok 为佳）"

# ───────────────────────────── C3. 机器可读输出 + 基线回归 diff ─────────────────────────────
hdr "能力矩阵 · 机器可读 (key=val；可作回归基线)"
KV_KEYS="net nss_tls oom psi trim watchdog fw_backfill ipv6_layer timesync apt_hold audio autorotate modem suspend fs_health fs_resize"
{ echo "# raphael caps $(date '+%F %T')"; for k in $KV_KEYS; do printf '%s=%s\n' "$k" "${CAP[$k]:-NA}"; done; } | tee "$KV" 2>/dev/null
cp -f "$KV" "${PWD}/raphael-caps-latest.kv" 2>/dev/null
echo "  （已写 $KV；下次用  bash device-probe.sh --baseline <旧.kv>  比对回归）"
if [ -n "$BASELINE" ] && [ -r "$BASELINE" ]; then
  sub "回归 diff（对比基线 $BASELINE）"
  chg=0
  while IFS='=' read -r k oldv; do
    case "$k" in ''|\#*) continue ;; esac
    newv="${CAP[$k]:-NA}"
    [ "$oldv" = "$newv" ] && continue
    chg=1; printf '  [Δ] %-14s %s → %s\n' "$k" "$oldv" "$newv"
  done < "$BASELINE"
  [ "$chg" = 0 ] && c_ok "与基线一致，无能力变化" || c_info "上面是与基线的能力变化（人工判断 ↑修复 / ↓回归）"
elif [ -n "$BASELINE" ]; then
  c_warn "指定的基线文件不可读: $BASELINE"
fi

printf '\n报告结束。\n'
}

main 2>&1 | tee "$REPORT"
echo
echo "================================================================"
echo "报告已保存：$REPORT"
echo "请把该文件内容【整段贴回】，我据此进行实际优化。"
echo "================================================================"
