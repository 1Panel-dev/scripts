#!/bin/bash

# Install Supervisor
# Support Ubuntu/Debian/CentOS/RHEL/Alpine/Arch Linux

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
    elif type lsb_release >/dev/null 2>&1; then
        OS=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
        VERSION=$(lsb_release -sr)
    elif [ -f /etc/redhat-release ]; then
        OS="rhel"
        VERSION=$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release)
    elif [ -f /etc/alpine-release ]; then
        OS="alpine"
        VERSION=$(cat /etc/alpine-release)
    else
        OS=$(uname -s | tr '[:upper:]' '[:lower:]')
        VERSION=$(uname -r)
    fi
}

install_supervisor() {
    echo -e "${GREEN}Detected system: $OS $VERSION${NC}"

    case "$OS" in
        ubuntu|debian)
            apt-get update
            apt-get install -y supervisor
            ;;
        centos|rhel|fedora)
            if [ "$OS" = "rhel" ] && [ "${VERSION%%.*}" -ge 8 ]; then
                dnf install -y supervisor
            else
                yum install -y supervisor
            fi
            ;;
        alpine)
            apk add --no-cache supervisor
            mkdir -p /etc/supervisor.d
            ;;
        arch)
            pacman -Sy --noconfirm supervisor
            ;;
        *)
            echo -e "${RED}Unsupported system${NC}"
            exit 1
            ;;
    esac
}

start_service() {
    echo -e "${GREEN}Start Supervisor...${NC}"
    
    case "$OS" in
        ubuntu|debian)
            systemctl enable supervisor
            systemctl restart supervisor
            ;;
        centos|rhel|fedora)
            systemctl enable supervisor
            systemctl restart supervisor
            ;;
        alpine)
            rc-update add supervisor
            rc-service supervisor start
            ;;
        arch)
            systemctl enable supervisor
            systemctl restart supervisor
            ;;
        *)
            echo -e "${YELLOW}The service cannot be started automatically. Please start manually!${NC}"
            ;;
    esac

    if command -v systemctl &> /dev/null; then
        systemctl status supervisor || true
    else
        rc-service supervisor status || true
    fi

     echo -e "${GREEN}Supervisor is installed and started${NC}"
}

main() {
    detect_os
    install_supervisor
    start_service
}

main "$@"