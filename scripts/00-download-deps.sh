#!/usr/bin/env bash
set -Eeuo pipefail

log() {
    printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
    log "ERROR: $*"
    exit 1
}

download_file() {
    local url="$1"
    local dest="$2"
    local tmp="${dest}.tmp"

    mkdir -p "$(dirname "$dest")"
    log "下载: $url"
    curl -fL --retry 5 --retry-delay 2 --connect-timeout 30 -o "$tmp" "$url"
    [ -s "$tmp" ] || die "下载结果为空: $url"
    mv -f "$tmp" "$dest"
}

download_uboot_image() {
    local archive="$1"
    local dest="$2"
    local extracted

    command -v unzip >/dev/null 2>&1 || die "缺少 unzip，无法解压 U-Boot 镜像"
    download_file "$UBOOT_IMG_URL" "$archive"
    unzip -tq "$archive" >/dev/null || die "U-Boot 压缩包校验失败: $archive"

    extracted="$(unzip -Z1 "$archive" | awk '/(^|\/)u-boot\.img$/ { print; exit }')"
    [ -n "$extracted" ] || die "U-Boot 压缩包中未找到 u-boot.img"

    unzip -p "$archive" "$extracted" > "$dest"
    [ -s "$dest" ] || die "解压出的 U-Boot 镜像为空: $dest"
}

sha256_file() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | awk '{print $1}'
	else
		die "缺少 sha256sum/shasum，无法生成 U-Boot 清单"
	fi
}

repack_uboot_variants() {
	local kernel_deb="$1"
	local workdir base_img dtb tmp_dest manifest_tmp
	local kernel_package kernel_version base_sha dtb_sha image_sha safe_dtb_sha=""
	local i
	local dtb_names=(
		"sm8150-xiaomi-raphael.dtb"
		"sm8150-xiaomi-raphael-audio-test.dtb"
		"sm8150-xiaomi-raphael-venus-test.dtb"
		"sm8150-xiaomi-raphael-bringup-test.dtb"
	)
	local variant_names=("safe" "audio-test" "venus-test" "bringup-test")
	local outputs=(
		"$UBOOT_IMG"
		"$UBOOT_AUDIO_TEST_IMG"
		"$UBOOT_VENUS_TEST_IMG"
		"$UBOOT_BRINGUP_TEST_IMG"
	)

	command -v dpkg-deb >/dev/null 2>&1 || die "缺少 dpkg-deb，无法从内核包提取 DTB"
	command -v python3 >/dev/null 2>&1 || die "缺少 python3，无法重新打包 U-Boot"
	mkdir -p "$(dirname "$UBOOT_IMG")" \
		"$(dirname "$UBOOT_SAFE_IMG")" \
		"$(dirname "$UBOOT_AUDIO_TEST_IMG")" \
		"$(dirname "$UBOOT_VENUS_TEST_IMG")" \
		"$(dirname "$UBOOT_BRINGUP_TEST_IMG")" \
		"$(dirname "$UBOOT_MANIFEST")"

	workdir="$(mktemp -d)" || die "无法创建 U-Boot 重打包临时目录"
	trap 'rm -rf "$workdir"' EXIT

	log "从内核包一次性提取安全版及 bring-up DTB"
	dpkg-deb -x "$kernel_deb" "$workdir/kernel"

	base_img="$workdir/u-boot-base.img"
	download_uboot_image "$workdir/u-boot.img.zip" "$base_img"
	base_sha="$(sha256_file "$base_img")"
	kernel_package="$(dpkg-deb -f "$kernel_deb" Package 2>/dev/null || printf unknown)"
	kernel_version="$(dpkg-deb -f "$kernel_deb" Version 2>/dev/null || printf unknown)"
	manifest_tmp="${UBOOT_MANIFEST}.tmp"

	{
		printf 'format=raphael-uboot-variants-v1\n'
		printf 'generated_utc=%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
		printf 'kernel_deb=%s\n' "$(basename "$kernel_deb")"
		printf 'kernel_package=%s\n' "$kernel_package"
		printf 'kernel_version=%s\n' "$kernel_version"
		printf 'base_uboot_url=%s\n' "$UBOOT_IMG_URL"
		printf 'base_uboot_sha256=%s\n' "$base_sha"
		printf 'variant\tdtb\tdtb_sha256\timage\timage_sha256\n'
	} > "$manifest_tmp"

	for i in "${!dtb_names[@]}"; do
		dtb="$(find "$workdir/kernel" -type f -name "${dtb_names[$i]}" -print -quit)"
		[ -n "$dtb" ] || die "内核包中未找到 ${dtb_names[$i]}: $kernel_deb"

		tmp_dest="${outputs[$i]}.tmp"
		rm -f "$tmp_dest"
		log "重打包 $(basename "${outputs[$i]}") <- ${dtb_names[$i]}"
		python3 "$SCRIPT_DIR/repack-uboot.py" "$base_img" "$dtb" "$tmp_dest"
		[ -s "$tmp_dest" ] || die "重新打包的 U-Boot 镜像为空: $tmp_dest"
		mv -f "$tmp_dest" "${outputs[$i]}"

		dtb_sha="$(sha256_file "$dtb")"
		image_sha="$(sha256_file "${outputs[$i]}")"
		if [ "$i" -eq 0 ]; then
			safe_dtb_sha="$dtb_sha"
		fi
		printf '%s\t%s\t%s\t%s\t%s\n' \
			"${variant_names[$i]}" "${dtb_names[$i]}" "$dtb_sha" \
			"$(basename "${outputs[$i]}")" "$image_sha" >> "$manifest_tmp"
	done

	# u-boot.img remains the backwards-compatible safe image name.  Keep an
	# explicit alias so test instructions cannot confuse it with a test DTB.
	if [ "$UBOOT_SAFE_IMG" != "$UBOOT_IMG" ]; then
		cp -f "$UBOOT_IMG" "$UBOOT_SAFE_IMG"
		printf 'safe-alias\t%s\t%s\t%s\t%s\n' \
			"${dtb_names[0]}" "$safe_dtb_sha" \
			"$(basename "$UBOOT_SAFE_IMG")" "$(sha256_file "$UBOOT_SAFE_IMG")" \
			>> "$manifest_tmp"
	fi

	mv -f "$manifest_tmp" "$UBOOT_MANIFEST"

	rm -rf "$workdir"
	trap - EXIT
}

download_kernel_deb() {
    local package="$1"
    local dest="$KERNEL_DEBS_DIR/${package}-xiaomi-raphael.deb"
    local url="https://github.com/$KERNEL_REPO/releases/download/$KERNEL_RELEASE_TAG/${package}-xiaomi-raphael.deb"

    download_file "$url" "$dest"
    if command -v dpkg-deb >/dev/null 2>&1; then
        dpkg-deb -f "$dest" Package Version Architecture >/dev/null
    fi
}

KERNEL_VERSION="${1:-${KERNEL_VERSION:-7.1}}"
KERNEL_REPO="${2:-${KERNEL_REPO:-fusion-hxf/kernel-deb}}"
KERNEL_REPO="${KERNEL_REPO#https://github.com/}"
KERNEL_REPO="${KERNEL_REPO#git@github.com:}"
KERNEL_REPO="${KERNEL_REPO%.git}"
KERNEL_REPO="${KERNEL_REPO%/}"
KERNEL_RELEASE_TAG="${KERNEL_RELEASE_TAG:-kernel-v$KERNEL_VERSION}"
OUT_DIR="${OUT_DIR:-$(pwd)}"
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL_DEBS_DIR="${KERNEL_DEBS_DIR:-$OUT_DIR/xiaomi-raphael-debs_$KERNEL_VERSION}"
BOOT_IMG="${BOOT_IMG:-$OUT_DIR/xiaomi-k20pro-boot.img}"
BOOT_IMG_URL="${BOOT_IMG_URL:-https://github.com/GengWei1997/kernel-deb/releases/download/v1.0.0/xiaomi-k20pro-boot.img}"
UBOOT_IMG="${UBOOT_IMG:-$OUT_DIR/u-boot.img}"
UBOOT_IMG_URL="${UBOOT_IMG_URL:-https://github.com/GengWei1997/linux-xiaomi-raphael-uboot/releases/download/v1.0.0/u-boot-sm8150-xiaomi-raphael.img.zip}"
UBOOT_SAFE_IMG="${UBOOT_SAFE_IMG:-$OUT_DIR/u-boot-safe.img}"
UBOOT_AUDIO_TEST_IMG="${UBOOT_AUDIO_TEST_IMG:-$OUT_DIR/u-boot-audio-test.img}"
UBOOT_VENUS_TEST_IMG="${UBOOT_VENUS_TEST_IMG:-$OUT_DIR/u-boot-venus-test.img}"
UBOOT_BRINGUP_TEST_IMG="${UBOOT_BRINGUP_TEST_IMG:-$OUT_DIR/u-boot-bringup-test.img}"
UBOOT_MANIFEST="${UBOOT_MANIFEST:-$OUT_DIR/u-boot-variants.tsv}"
INCLUDE_ALSA="${INCLUDE_ALSA:-1}"

log "准备下载 rootfs 构建依赖"
log "内核版本:      $KERNEL_VERSION"
log "内核包仓库:    $KERNEL_REPO"
log "Release tag:   $KERNEL_RELEASE_TAG"
log "内核包目录:    $KERNEL_DEBS_DIR"
log "cache boot image: $BOOT_IMG"
log "U-Boot safe:   $UBOOT_IMG"
log "U-Boot audio:  $UBOOT_AUDIO_TEST_IMG"
log "U-Boot Venus:  $UBOOT_VENUS_TEST_IMG"

download_kernel_deb linux-image
download_kernel_deb linux-headers
download_kernel_deb firmware

if [ "$INCLUDE_ALSA" != "0" ]; then
    download_kernel_deb alsa
fi

download_file "$BOOT_IMG_URL" "$BOOT_IMG"
repack_uboot_variants "$KERNEL_DEBS_DIR/linux-image-xiaomi-raphael.deb"

log "下载完成"
ls -lh "$KERNEL_DEBS_DIR"
ls -lh "$BOOT_IMG"
ls -lh "$UBOOT_IMG" "$UBOOT_SAFE_IMG" "$UBOOT_AUDIO_TEST_IMG" \
	"$UBOOT_VENUS_TEST_IMG" "$UBOOT_BRINGUP_TEST_IMG" "$UBOOT_MANIFEST"
