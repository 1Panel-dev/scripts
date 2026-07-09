#!/bin/bash

# Install KVM Environment
# Support Ubuntu/Debian/CentOS/Rocky/AlmaLinux/RHEL/Kylin

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

OS=""
VERSION=""

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS="$ID"
        VERSION="$VERSION_ID"

        case "$OS" in
            kylin|kylin-server|openkylin)
                OS="kylin"
                ;;
        esac
    elif [ -f /etc/redhat-release ]; then
        OS="rhel"
        VERSION=$(grep -oE '[0-9]+' /etc/redhat-release | head -1)
    else
        echo -e "${RED}Unsupported operating system.${NC}"
        exit 1
    fi
}

install_packages() {
    echo -e "${GREEN}Detected system: ${OS} ${VERSION}${NC}"
    echo -e "${GREEN}Installing KVM environment...${NC}"

    case "$OS" in
        ubuntu|debian)
            export DEBIAN_FRONTEND=noninteractive

            apt-get update

            apt-get install -y \
                qemu-kvm \
                qemu-utils \
                libvirt-daemon-system \
                libvirt-clients \
                virtinst
            ;;

        centos|rocky|almalinux|rhel|kylin)
            if command -v dnf >/dev/null 2>&1; then
                PKG=dnf
            elif command -v yum >/dev/null 2>&1; then
                PKG=yum
            else
                echo -e "${RED}Neither dnf nor yum was found.${NC}"
                exit 1
            fi

            $PKG install -y \
                qemu-kvm \
                qemu-img \
                libvirt \
                libvirt-client \
                virt-install
            ;;

        *)
            echo -e "${RED}Unsupported system: ${OS}${NC}"
            exit 1
            ;;
    esac
}

start_libvirt() {
    echo -e "${GREEN}Starting libvirt service...${NC}"

    systemctl enable libvirtd >/dev/null 2>&1 || true
    systemctl restart libvirtd
}

check_libvirt() {
    echo -e "${GREEN}Checking libvirt...${NC}"

    if systemctl is-active --quiet libvirtd; then
        echo -e "${GREEN}✓ libvirt is running.${NC}"
    else
        echo -e "${RED}✗ libvirt is not running.${NC}"
        exit 1
    fi
}

print_summary() {
    echo
    echo -e "${GREEN}KVM environment installation completed successfully.${NC}"
    echo
    echo -e "${YELLOW}Installed Components:${NC}"
    echo "  ✓ qemu-kvm"
    echo "  ✓ libvirt"
    echo "  ✓ qemu-img"
    echo "  ✓ virt-install"
    echo
}

main() {
    detect_os
    install_packages
    start_libvirt
    check_libvirt
    print_summary
}

main "$@"
