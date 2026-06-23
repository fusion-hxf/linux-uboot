#!/bin/bash
set -e

HOSTNAME="${HOSTNAME:-xiaomi-raphael}"
# 构建期临时 DNS（仅供 bootstrap/apt 使用）。出厂 resolv.conf 在 15-cleanup.sh
# 收口到 systemd-resolved；这里默认改用国内可达的 223.5.5.5，避免本地构建解析被干扰。
NAMESERVER="${NAMESERVER:-223.5.5.5}"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [04] 🌐 配置网络和主机名"

rm -f rootdir/etc/resolv.conf
touch rootdir/etc/resolv.conf

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [04]   └─ 主机名: ${HOSTNAME}"
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [04]   └─ DNS: ${NAMESERVER}"

echo "nameserver ${NAMESERVER}" > rootdir/etc/resolv.conf
echo "${HOSTNAME}" > rootdir/etc/hostname
echo "127.0.0.1 localhost
127.0.1.1 ${HOSTNAME}" > rootdir/etc/hosts

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [04] ✅ 网络配置完成"