#!/bin/bash
set -e

ROOT_PASS="${ROOT_PASS:-1234}"
USER_NAME="${USER_NAME:-user}"
USER_PASS="${USER_PASS:-1234}"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [12] 👤 创建用户和配置 SSH"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [12]   └─ 创建用户: ${USER_NAME}"
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [12]   └─ 启用 SSH 密码登录"

echo "root:${ROOT_PASS}" | chroot rootdir chpasswd
chroot rootdir useradd -m -G sudo -s /bin/bash ${USER_NAME}
echo "${USER_NAME}:${USER_PASS}" | chroot rootdir chpasswd

# [P1] 用 drop-in 配置，避免被 sshd_config 中更靠前的同名项无声覆盖（sshd 首条匹配生效）
mkdir -p rootdir/etc/ssh/sshd_config.d
cat > rootdir/etc/ssh/sshd_config.d/10-raphael.conf << 'EOF'
PermitRootLogin yes
PasswordAuthentication yes
EOF

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [12] ✅ 用户创建完成"
