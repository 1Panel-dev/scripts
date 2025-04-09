#!/bin/bash

# Install Firewalld | Ufw
# Support Ubuntu/Debian/CentOS/RHEL/Alpine/Arch Linux

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

FIREWALL=""


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

install_firewall() {
    if [ "$OS" == "ubuntu" ] || [ "$OS" == "debian" ]; then
        echo -e "${GREEN}Detected system: $OS $VERSION, start to install ufw...${NC}"
        FIREWALL="ufw"
        apt-get update
        apt-get install -y ufw
    elif [ "$OS" == "centos" ] || [ "$OS" == "rhel" ] || [ "$OS_LIKE" == "rhel" ]; then
        echo -e "${GREEN}Detected system: $OS $VERSION, start to install firewall...${NC}"
        FIREWALL="firewalld"
        yum update
        yum install -y firewalld
    else
        echo -e "${RED}Unsupported system: $OS $VERSION${NC}"
        exit 1
    fi
}

start_with_init() {
    read -p "Please enter the ports to be allowed (separate multiple ports with spaces, e.g., 80 443 22): " PORTS

    if [ -z "$PORTS" ]; then
        echo -e "${RED}Error: No port was entered!${NC}"
        exit 1
    fi

    case $FIREWALL in
        firewalld)
            echo -e "${GREEN}Initialize and start firewalld...${NC}"
            systemctl start firewalld
            systemctl enable firewalld
            
            for port in $PORTS; do
                firewall-cmd --zone=public --permanent --add-port="$port/tcp"
            done
            
            firewall-cmd --reload
            echo -e "${GREEN}The following TCP ports have been allowed: $PORTS ${NC}"
            ;;
            
        ufw)
            echo -e "${GREEN}Initialize and start ufw...${NC}"
            ufw --force enable
            
            for port in $PORTS; do
                ufw allow "$port/tcp"
            done
            
            echo -e "${GREEN}The following TCP ports have been allowed: $PORTS ${NC}"
            ;;
    esac
}

check_install() {
    if [ "$FIREWALL" = "firewalld" ]; then
        if command -v firewall-cmd &> /dev/null; then
            systemctl status firewalld || true
        fi
    else 
        if command -v ufw &> /dev/null; then
            ufw status || true
        fi
    fi

    echo -e "${GREEN}$FIREWALL is installed and started${NC}"
}

main() {
    detect_os
    install_firewall
    start_with_init
    check_install
}

main "$@"