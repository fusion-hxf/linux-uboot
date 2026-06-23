# 系统类型配置
SYSTEM_TYPES="
  debian-server
  debian-gnome
  debian-phosh
  ubuntu-server
  ubuntu-gnome
  ubuntu-phosh
"

# 系统类型到基础设置的映射
system_config() {
  case "$1" in
    "debian-server")
      echo "DEBIAN_VERSION=${DEBIAN_VERSION:-trixie}"
      echo "IMAGE_SIZE=3G"
      echo "IS_DESKTOP=false"
      echo "DESKTOP_ENV="
      ;;
    "debian-gnome")
      echo "DEBIAN_VERSION=${DEBIAN_VERSION:-trixie}"
      echo "IMAGE_SIZE=6G"
      echo "IS_DESKTOP=true"
      echo "DESKTOP_ENV=gnome"
      ;;
    "debian-phosh")
      echo "DEBIAN_VERSION=${DEBIAN_VERSION:-trixie}"
      echo "IMAGE_SIZE=6G"
      echo "IS_DESKTOP=true"
      echo "DESKTOP_ENV=$2"
      ;;
    "ubuntu-server")
      echo "UBUNTU_VERSION=${UBUNTU_VERSION:-resolute}"
      echo "IMAGE_SIZE=3G"
      echo "IS_DESKTOP=false"
      echo "DESKTOP_ENV="
      ;;
    "ubuntu-gnome")
      echo "UBUNTU_VERSION=${UBUNTU_VERSION:-resolute}"
      echo "IMAGE_SIZE=6G"
      echo "IS_DESKTOP=true"
      echo "DESKTOP_ENV=gnome"
      ;;
    "ubuntu-phosh")
      echo "UBUNTU_VERSION=${UBUNTU_VERSION:-resolute}"
      echo "IMAGE_SIZE=6G"
      echo "IS_DESKTOP=true"
      echo "DESKTOP_ENV=$2"
      ;;
  esac
}

# 镜像源配置
sources_config() {
  if [[ "$1" == *"debian-"* ]]; then
    local version="${DEBIAN_VERSION:-trixie}"
    echo "DEBIAN_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/debian/"
    echo "DEBIAN_SECURITY_MIRROR=http://security.debian.org/debian-security"
  elif [[ "$1" == *"ubuntu-"* ]]; then
    local version="${UBUNTU_VERSION:-resolute}"
    echo "UBUNTU_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/"
    echo "UBUNTU_SECURITY_MIRROR=http://ports.ubuntu.com/ubuntu-ports/"
  fi
}

# 注：软件包清单（base/device/desktop）现内联在 scripts/06-install-all-packages.sh。
# 旧的 get_packages() 已删除——之前未被任何脚本调用（死代码）。