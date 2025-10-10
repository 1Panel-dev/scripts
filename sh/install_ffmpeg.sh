#!/bin/bash

# Install FFmpeg
# Support Ubuntu/Debian/CentOS/RHEL/Alpine/Arch Linux

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

OS=""
VERSION=""

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
        if [ -n "$ID_LIKE" ]; then
            OS_LIKE=$ID_LIKE
        fi
    elif type lsb_release >/dev/null 2>&1; then
        OS=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
        VERSION=$(lsb_release -sr)
    elif [ -f /etc/redhat-release ]; then
        OS="rhel"
        VERSION=$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release)
        OS_LIKE="rhel"
    elif [ -f /etc/alpine-release ]; then
        OS="alpine"
        VERSION=$(cat /etc/alpine-release)
    else
        OS=$(uname -s | tr '[:upper:]' '[:lower:]')
        VERSION=$(uname -r)
    fi
}

install_ffmpeg() {
    echo -e "${GREEN}Detected system: $OS $VERSION, start to install FFmpeg...${NC}"
    case "$OS" in
        ubuntu|debian)
            apt-get update
            apt-get install -y ffmpeg
            ;;
        centos|rhel|fedora)
            if [ "$OS" = "rhel" ] && [ "${VERSION%%.*}" -ge 8 ]; then
                # CentOS 8 / RHEL 8+
                dnf install -y epel-release
                dnf install -y https://download1.rpmfusion.org/free/el/rpmfusion-free-release-$(rpm -E %rhel).noarch.rpm
                dnf install -y ffmpeg ffmpeg-devel
            else
                # CentOS 7 / RHEL 7
                yum install -y epel-release
                yum install -y https://download1.rpmfusion.org/free/el/rpmfusion-free-release-7.noarch.rpm
                yum install -y ffmpeg ffmpeg-devel || {
                    # fallback to Nux Dextop if still not available
                    rpm --import http://li.nux.ro/download/nux/RPM-GPG-KEY-nux.ro
                    rpm -Uvh http://li.nux.ro/download/nux/dextop/el7/x86_64/nux-dextop-release-0-1.el7.nux.noarch.rpm
                    yum install -y ffmpeg ffmpeg-devel
                }
            fi
            ;;
        alpine)
            apk update
            apk add ffmpeg
            ;;
        arch)
            pacman -Sy --noconfirm ffmpeg
            ;;
        *)
            echo -e "${RED}Unsupported system: $OS $VERSION${NC}"
            exit 1
            ;;
    esac
}

check_ffmpeg_install() {
    if command -v ffmpeg >/dev/null 2>&1; then
        echo -e "${GREEN}FFmpeg is installed. Version: $(ffmpeg -version | head -n 1)${NC}"
    else
        echo -e "${RED}FFmpeg installation failed or not found.${NC}"
        exit 1
    fi
}

main() {
    detect_os
    install_ffmpeg
    check_ffmpeg_install
}

main "$@"

