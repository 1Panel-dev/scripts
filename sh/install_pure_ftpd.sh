#!/bin/bash

# Install Pure-FTPd
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

install_pureftpd() {
    echo -e "${GREEN}Detected system: $OS $VERSION${NC}"

    case "$OS" in
        ubuntu|debian)
            apt-get update
            apt-get install -y pure-ftpd
            ;;
        centos|rhel|fedora)
            if [ "$OS" = "rhel" ] && [ "${VERSION%%.*}" -ge 8 ]; then
                dnf install -y epel-release
                dnf install -y pure-ftpd
            else
                yum install -y epel-release
                yum install -y pure-ftpd
            fi
            ;;
        alpine)
            apk add --no-cache pure-ftpd
            ;;
        arch)
            pacman -Sy --noconfirm pure-ftpd
            ;;
        *)
            echo -e "${RED}Unsupported system${NC}"
            exit 1
            ;;
    esac

    if ! command -v pure-ftpd &> /dev/null; then
        echo -e "${RED}Install Pure-FTPd failed${NC}"
        exit 1
    fi
}

configure_pureftpd() {
    echo -e "${GREEN}Configure Pure-FTPd...${NC}"
    
    PURE_FTPD_CONF="/etc/pure-ftpd/pure-ftpd.conf"
    if [ -f "$PURE_FTPD_CONF" ]; then
        cp "$PURE_FTPD_CONF" "$PURE_FTPD_CONF.bak"
        sed -i 's/^NoAnonymous[[:space:]]\+no$/NoAnonymous yes/' "$PURE_FTPD_CONF"
        sed -i 's/^PAMAuthentication[[:space:]]\+yes$/PAMAuthentication no/' "$PURE_FTPD_CONF"
        sed -i 's/^# PassivePortRange[[:space:]]\+30000 50000$/PassivePortRange 39000 40000/' "$PURE_FTPD_CONF"
        sed -i 's/^VerboseLog[[:space:]]\+no$/VerboseLog yes/' "$PURE_FTPD_CONF"
        sed -i 's/^# PureDB[[:space:]]\+\/etc\/pure-ftpd\/pureftpd\.pdb[[:space:]]*$/PureDB \/etc\/pure-ftpd\/pureftpd.pdb/' "$PURE_FTPD_CONF"
    else
        touch /etc/pure-ftpd/pureftpd.pdb
        chmod 644 /etc/pure-ftpd/pureftpd.pdb
        echo '/etc/pure-ftpd/pureftpd.pdb' > /etc/pure-ftpd/conf/PureDB
        echo yes > /etc/pure-ftpd/conf/VerboseLog 
        echo yes > /etc/pure-ftpd/conf/NoAnonymous
        echo '39000 40000' > /etc/pure-ftpd/conf/PassivePortRange
        echo 'no' > /etc/pure-ftpd/conf/PAMAuthentication
        echo 'no' > /etc/pure-ftpd/conf/UnixAuthentication
        echo 'clf:/var/log/pure-ftpd/transfer.log' > /etc/pure-ftpd/conf/AltLog
        ln -s /etc/pure-ftpd/conf/PureDB /etc/pure-ftpd/auth/50puredb
    fi
}

start_service() {
    echo -e "${GREEN}Start Pure-FTPd...${NC}"
    
    case "$OS" in
        ubuntu|debian)
            systemctl enable pure-ftpd
            systemctl restart pure-ftpd
            ;;
        centos|rhel|fedora)
            systemctl enable pure-ftpd
            systemctl restart pure-ftpd
            ;;
        alpine)
            rc-update add pure-ftpd
            rc-service pure-ftpd start
            ;;
        arch)
            systemctl enable pure-ftpd
            systemctl restart pure-ftpd
            ;;
        *)
            echo -e "${YELLOW}The service cannot be started automatically. Please start manually!${NC}"
            ;;
    esac

    if command -v systemctl &> /dev/null; then
        systemctl status pure-ftpd || true
    else
        rc-service pure-ftpd status || true
    fi

    echo -e "${GREEN}Pure-FTPd is installed and started${NC}"
}

main() {
    detect_os
    install_pureftpd
    configure_pureftpd
    start_service
}

main "$@"