#!/usr/bin/env python3
# =============================================================================
# repack-uboot.py —— 复用一份"已知可启动"的 u-boot.img 里的 U-Boot 二进制，
#                    只把追加的 DTB 换成新的（带音频的）那份，重新打包成 boot image。
#
# 为什么这样做：raphael 的 u-boot.img = Android boot image(v0)，其 kernel 负载 =
#   gzip(u-boot-nodtb.bin) + 追加的 DTB。U-Boot 用这份追加 DTB 作 control FDT 并传给内核。
#   从主线源码重编 U-Boot 容易引导不了 raphael；而 GengWei v1.0.0 的二进制是验证可用的，
#   故复用它、只换 DTB，最稳。
#
# 用法:
#   python3 repack-uboot.py <已知可用的 u-boot.img> <新.dtb> <输出 u-boot.img>
# 取新 dtb:
#   dpkg-deb -x linux-image-xiaomi-raphael.deb t && find t -name sm8150-xiaomi-raphael.dtb
# =============================================================================
import sys, struct, zlib, hashlib

if len(sys.argv) != 4:
    sys.exit("用法: repack-uboot.py <源u-boot.img> <新.dtb> <输出.img>")
src, newdtb_path, out = sys.argv[1], sys.argv[2], sys.argv[3]

img = open(src, 'rb').read()
if img[:8] != b'ANDROID!':
    sys.exit("源不是 Android boot image (magic 不符)")

header_size = 1632
if len(img) < header_size:
    sys.exit("源 Android boot image 头部不完整")

# 头部参数原样沿用（page/各 addr），保证与源镜像结构一致
page = struct.unpack('<I', img[36:40])[0]
ksz  = struct.unpack('<I', img[8:12])[0]
ramdisk_size = struct.unpack('<I', img[16:20])[0]
second_size = struct.unpack('<I', img[24:28])[0]
kaddr, raddr, saddr, tags = (struct.unpack('<I', img[o:o+4])[0] for o in (12, 20, 28, 32))

if page < header_size or page & (page - 1):
    sys.exit("源镜像 page size 非法: %d" % page)
if ramdisk_size or second_size:
    sys.exit("源镜像包含 ramdisk/second stage，拒绝静默丢弃")
if not ksz or page + ksz > len(img):
    sys.exit("源镜像 kernel payload 长度越界")

def align(value):
    return (value + page - 1) // page * page

if len(img) != page + align(ksz):
    sys.exit("源镜像含未识别的尾部数据，拒绝重打包")

# 从 kernel 负载里拆出 u-boot.gz（gzip 流自终止，unused_data 即追加的旧 dtb）
payload = img[page:page+ksz]
do = zlib.decompressobj(31)
try:
    do.decompress(payload)
except zlib.error as exc:
    sys.exit("源 kernel payload 不是有效 gzip: %s" % exc)
if not do.eof:
    sys.exit("源 U-Boot gzip 流不完整")
gz = payload[:len(payload) - len(do.unused_data)]
old_dtb = do.unused_data
if len(old_dtb) < 8 or old_dtb[:4] != bytes.fromhex('d00dfeed'):
    sys.exit("源 U-Boot gzip 后没有合法追加 DTB")
if struct.unpack('>I', old_dtb[4:8])[0] != len(old_dtb):
    sys.exit("源追加 DTB totalsize 与实际长度不符")

newdtb = open(newdtb_path, 'rb').read()
if len(newdtb) < 8 or newdtb[:4] != bytes.fromhex('d00dfeed'):
    sys.exit("新 dtb 不是合法 FDT (magic 应为 d00dfeed)")
if struct.unpack('>I', newdtb[4:8])[0] != len(newdtb):
    sys.exit("新 dtb totalsize 与实际长度不符")

kernel = gz + newdtb     # 复用的 u-boot.gz + 新 dtb

def pad(b):
    r = len(b) % page
    return b + b'\x00' * (page - r) if r else b

sha = hashlib.sha1()
for blob, size in ((kernel, len(kernel)), (b'', 0), (b'', 0)):
    sha.update(blob); sha.update(struct.pack('<I', size))
img_id = sha.digest()

hdr  = b'ANDROID!'
hdr += struct.pack('<10I', len(kernel), kaddr, 0, raddr, 0, saddr, tags, page, 0, 0)
hdr += b'\x00'*16 + b'\x00'*512                  # name + cmdline
hdr += img_id + b'\x00'*(32-len(img_id))         # id[8]
hdr += b'\x00'*1024                              # extra_cmdline
open(out, 'wb').write(pad(hdr) + pad(kernel))
print("OK -> %s  (复用 u-boot.gz %d + 新 dtb %d；page=%d, kernel@0x%x)"
      % (out, len(gz), len(newdtb), page, kaddr))
