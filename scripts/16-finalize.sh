#!/bin/bash
set -e

IMAGE_NAME="${IMAGE_NAME:-rootfs.img}"
IMAGE_UUID="${IMAGE_UUID:-ee8d3593-59b1-480e-a3b6-4fefb17ee7d8}"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [16] 📦 卸载并完成镜像"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [16]   └─ 卸载挂载点..."
umount rootdir/sys 2>/dev/null || true
umount rootdir/proc 2>/dev/null || true
umount rootdir/dev/pts 2>/dev/null || true
umount rootdir/dev 2>/dev/null || true
umount rootdir/boot 2>/dev/null || true
umount rootdir 2>/dev/null || true

rm -d rootdir 2>/dev/null || true

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [16]   └─ 设置镜像 UUID: ${IMAGE_UUID}"
e2fsck -f -y ${IMAGE_NAME}
tune2fs -U ${IMAGE_UUID} ${IMAGE_NAME}

# 转换为稀疏镜像 (Android sparse)。原始 raw ext4 镜像（IMAGE_SIZE，如 3G）刷 userdata 时，
# fastboot 需把整个 raw 文件读进内存重新切块（raw 无法识别空洞），在 Windows 上会因一次性
# 分配 ~3G 而抛 std::bad_alloc 崩溃。转成 sparse 后空白块标记为 don't-care，fastboot 按
# max-download-size 流式下发，只传实际占用的数据，刷写稳定。注意：转换须在 e2fsck/tune2fs
# 之后做（稀疏镜像不能直接 fsck / loop 挂载，需要 simg2img 还原），且不改变 UUID。
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [16]   └─ 转换为稀疏镜像 (sparse)..."
if ! command -v img2simg >/dev/null 2>&1; then
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] [16] ❌ 错误: 未找到 img2simg，请安装 android-sdk-libsparse-utils"
  exit 1
fi
img2simg ${IMAGE_NAME} ${IMAGE_NAME}.sparse
mv -f ${IMAGE_NAME}.sparse ${IMAGE_NAME}

echo ""
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [16]   └─ Legacy boot cmdline: root=PARTLABEL=userdata"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [16] ✅ 镜像完成"
