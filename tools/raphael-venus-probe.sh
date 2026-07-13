#!/bin/bash
set -Eeuo pipefail

if [ "$(id -u)" -ne 0 ]; then
	echo "请使用 sudo 运行: sudo $0" >&2
	exit 1
fi

USER_NAME="${SUDO_USER:-user}"
BASE_DIR="${1:-/home/$USER_NAME/venus-bringup}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$BASE_DIR/$STAMP"
LOG="$OUT_DIR/probe.log"
KMSG="$OUT_DIR/kmsg-follow.log"
SYNC_PID=""
KMSG_PID=""
OLD_CONSOLE_LOGLEVEL=""
VENUS_FW_STAGE="${VENUS_FW_STAGE:-1}"
VENUS_CHECKPOINT_MS="${VENUS_CHECKPOINT_MS:-1500}"
VENUS_FW_HOLD_MS="${VENUS_FW_HOLD_MS:-100}"
VENUS_PROBE_STAGE="${VENUS_PROBE_STAGE:-0}"
VENUS_PAS_PRE_SHUTDOWN="${VENUS_PAS_PRE_SHUTDOWN:-1}"

case "$VENUS_FW_STAGE" in
	0|1|2|3|4|5) ;;
	*) echo "VENUS_FW_STAGE 必须是 0(full)、1(map)、2(load)、3(auth-stop)、4(protect-stop) 或 5(hold-stop)" >&2; exit 1 ;;
esac
case "$VENUS_CHECKPOINT_MS" in
	''|*[!0-9]*) echo "VENUS_CHECKPOINT_MS 必须是非负整数" >&2; exit 1 ;;
esac
case "$VENUS_FW_HOLD_MS" in
	''|*[!0-9]*) echo "VENUS_FW_HOLD_MS 必须是非负整数" >&2; exit 1 ;;
esac
case "$VENUS_PROBE_STAGE" in
	0|1|2|3|4) ;;
	*) echo "VENUS_PROBE_STAGE 必须是 0(full)、1(boot-stop)、2(cfg-stop)、3(resume-stop) 或 4(init-stop)" >&2; exit 1 ;;
esac
case "$VENUS_PAS_PRE_SHUTDOWN" in
	0|1) ;;
	*) echo "VENUS_PAS_PRE_SHUTDOWN 必须是 0 或 1" >&2; exit 1 ;;
esac

if ! findmnt -rn /home >/dev/null; then
	echo "拒绝探测：/home 未挂载，无法保证 watchdog 重启后日志仍在" >&2
	exit 1
fi

mkdir -p "$OUT_DIR"
chmod 0755 "$BASE_DIR" "$OUT_DIR"
exec > >(tee -a "$LOG") 2>&1

ATTEMPT_FILE=/run/raphael-venus-pas-attempts
PAS_ATTEMPT=0
if [ -r "$ATTEMPT_FILE" ]; then
	read -r PAS_ATTEMPT < "$ATTEMPT_FILE" || PAS_ATTEMPT=0
fi
PAS_ATTEMPT=$((PAS_ATTEMPT + 1))
echo "$PAS_ATTEMPT" > "$ATTEMPT_FILE"

checkpoint() {
	echo "[$(date --iso-8601=seconds)] $*"
	sync
}

cleanup() {
	local rc=$?

	[ -z "$KMSG_PID" ] || kill "$KMSG_PID" 2>/dev/null || true
	[ -z "$SYNC_PID" ] || kill "$SYNC_PID" 2>/dev/null || true
	[ -z "$OLD_CONSOLE_LOGLEVEL" ] ||
		dmesg -n "$OLD_CONSOLE_LOGLEVEL" 2>/dev/null || true
	dmesg > "$OUT_DIR/dmesg-exit.txt" 2>/dev/null || true
	echo "$rc" > "$OUT_DIR/exit-status.txt"
	chown -R "$USER_NAME:$USER_NAME" "$OUT_DIR" 2>/dev/null || true
	sync
	exit "$rc"
}
trap cleanup EXIT

checkpoint "Venus manual probe start; output=$OUT_DIR"

# dev_info() breadcrumbs are level 6.  Raise the console threshold so ramoops
# receives them as well as the printk ring buffer; restore it on a clean exit.
OLD_CONSOLE_LOGLEVEL="$(cut -d " " -f 1 /proc/sys/kernel/printk)"
cat /proc/sys/kernel/printk > "$OUT_DIR/printk-before.txt"
dmesg -n 8
checkpoint "console loglevel raised: $OLD_CONSOLE_LOGLEVEL -> 8"

echo "=== identity ==="
uname -a
findmnt /home
modinfo venus_core > "$OUT_DIR/venus-core-modinfo.txt"
sha256sum "$(modinfo -n venus_core)" > "$OUT_DIR/venus-core.sha256"
tr '\0' '\n' </proc/device-tree/model
tr '\0' '\n' </proc/device-tree/compatible
tr '\0' '\n' </proc/device-tree/soc@0/video-codec@aa00000/status

if ! tr '\0' '\n' </proc/device-tree/compatible |
	grep -qx 'xiaomi,raphael-venus-test'; then
	echo "拒绝探测：当前不是 venus-test DTB" >&2
	exit 2
fi

if grep -qw venus_core /proc/modules; then
	if [ -L /sys/bus/platform/devices/aa00000.video-codec/driver ]; then
		echo "拒绝探测：venus_core 已绑定，避免重复触碰硬件" >&2
		exit 3
	fi
	checkpoint "venus_core was safety-gated; unloading before explicit probe"
	modprobe -r venus_core
fi

# Load the media/V4L2 dependency stack through the driver's default safety
# gate.  This keeps dependency initialization separate from the risky hardware
# probe and makes the persisted trace start at the Venus-specific operation.
checkpoint "preloading media dependencies through Iris1 safety gate"
modprobe -v venus_core
if [ -L /sys/bus/platform/devices/aa00000.video-codec/driver ]; then
	echo "拒绝探测：安全预加载意外绑定了 Venus 驱动" >&2
	exit 3
fi
modprobe -r venus_core
checkpoint "media dependencies preloaded; venus_core unloaded"

echo "=== pre-probe power and clocks ==="
for attr in identity state timeout timeleft; do
	[ ! -r "/sys/class/watchdog/watchdog0/$attr" ] ||
		printf '%s=%s\n' "$attr" "$(cat "/sys/class/watchdog/watchdog0/$attr")"
done
grep -iE 'venus|vcodec|mmcx' \
	/sys/kernel/debug/pm_genpd/pm_genpd_summary 2>/dev/null || true
grep -iE 'gcc_video_axi[0-9c]_clk|video_cc_(mvsc|mvs0)_core_clk' \
	/sys/kernel/debug/clk/clk_summary 2>/dev/null || true
dmesg > "$OUT_DIR/dmesg-before.txt"
cp /sys/kernel/debug/pm_genpd/pm_genpd_summary \
	"$OUT_DIR/pm-genpd-before.txt" 2>/dev/null || true
cp /sys/kernel/debug/clk/clk_summary \
	"$OUT_DIR/clk-summary-before.txt" 2>/dev/null || true
mkdir -p "$OUT_DIR/pstore-before"
cp -a /sys/fs/pstore/. "$OUT_DIR/pstore-before/" 2>/dev/null || true

# Follow printk into persistent /home.  The sync loop limits loss if the NoC
# wedges and the hardware watchdog resets the phone before userspace can exit.
stdbuf -oL -eL dmesg --follow --human >"$KMSG" 2>&1 &
KMSG_PID=$!
(
	while :; do
		sync -f "$KMSG" 2>/dev/null || sync
		sleep 0.1
	done
) &
SYNC_PID=$!

sleep 2
if ! kill -0 "$KMSG_PID" 2>/dev/null; then
	echo "拒绝探测：persistent kmsg logger 未保持运行" >&2
	exit 4
fi
checkpoint "persistent logger active (pid=$KMSG_PID); loading venus_core explicitly"
checkpoint "diagnostic attempt=$PAS_ATTEMPT fw_stage=$VENUS_FW_STAGE hold_ms=$VENUS_FW_HOLD_MS probe_stage=$VENUS_PROBE_STAGE pre_shutdown=$VENUS_PAS_PRE_SHUTDOWN checkpoint_ms=$VENUS_CHECKPOINT_MS"
modprobe -v venus_core allow_iris1_probe=1 \
	iris1_fw_stage="$VENUS_FW_STAGE" \
	iris1_fw_checkpoint_ms="$VENUS_CHECKPOINT_MS" \
	iris1_fw_hold_ms="$VENUS_FW_HOLD_MS" \
	iris1_probe_stage="$VENUS_PROBE_STAGE" \
	iris1_pas_pre_shutdown="$VENUS_PAS_PRE_SHUTDOWN"
checkpoint "modprobe returned successfully"

sleep 2
dmesg > "$OUT_DIR/dmesg-after.txt"
lsmod > "$OUT_DIR/lsmod-after.txt"

if [ ! -L /sys/bus/platform/devices/aa00000.video-codec/driver ]; then
	echo "探测失败：modprobe 返回成功，但 aa00000.video-codec 未绑定" >&2
	grep -iE 'venus|iris1|video-codec|firmware|gdsc|clock|reset|smmu|iommu' \
		"$OUT_DIR/dmesg-after.txt" | tail -n 300 || true
	modprobe -r venus_core 2>/dev/null || true
	exit 5
fi

ls -l /dev/video* /dev/media* > "$OUT_DIR/video-nodes.txt" 2>&1 || true
v4l2-ctl --list-devices > "$OUT_DIR/v4l2-devices.txt" 2>&1 || true

echo "=== driver ==="
readlink /sys/bus/platform/devices/aa00000.video-codec/driver || true
cat "$OUT_DIR/video-nodes.txt"
cat "$OUT_DIR/v4l2-devices.txt"
checkpoint "Venus manual probe complete"
