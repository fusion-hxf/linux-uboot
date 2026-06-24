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

# 头部参数原样沿用（page/各 addr），保证与源镜像结构一致
page = struct.unpack('<I', img[36:40])[0]
ksz  = struct.unpack('<I', img[8:12])[0]
kaddr, raddr, saddr, tags = (struct.unpack('<I', img[o:o+4])[0] for o in (12, 20, 28, 32))

# 从 kernel 负载里拆出 u-boot.gz（gzip 流自终止，unused_data 即追加的旧 dtb）
payload = img[page:page+ksz]
do = zlib.decompressobj(31)
do.decompress(payload)
gz = payload[:len(payload) - len(do.unused_data)]

newdtb = open(newdtb_path, 'rb').read()
if newdtb[:4] != bytes.fromhex('d00dfeed'):
    sys.exit("新 dtb 不是合法 FDT (magic 应为 d00dfeed)")

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
