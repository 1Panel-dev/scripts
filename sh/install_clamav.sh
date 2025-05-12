#!/bin/bash

# Install ClamAV
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

install_clamav() {
    echo -e "${GREEN}Detected system: $OS $VERSION${NC}"

    case "$OS" in
        ubuntu|debian)
            apt-get update
            apt-get install -y clamav clamav-daemon clamav-freshclam
            ;;
        centos|rhel|fedora)
            if [ "$OS" = "rhel" ] && [ "${VERSION%%.*}" -ge 8 ]; then
                dnf install -y epel-release
                dnf install -y clamav clamd clamav-update
            else
                yum install -y epel-release
                yum install -y clamav clamd clamav-update
            fi
            ;;
        alpine)
            apk add --no-cache clamav clamav-libunrar clamav-daemon clamav-freshclam
            ;;
        arch)
            pacman -Sy --noconfirm clamav
            ;;
        *)
            echo -e "${RED}Unsupported system${NC}"
            exit 1
            ;;
    esac
}

configure_clamd() {
    echo -e "${GREEN}Configure clamd...${NC}"
    
    CLAMD_CONF=""
    if [ -f "/etc/clamd.d/scan.conf" ]; then
        CLAMD_CONF="/etc/clamd.d/scan.conf"
    elif [ -f "/etc/clamav/clamd.conf" ]; then
        CLAMD_CONF="/etc/clamav/clamd.conf"
    else
        echo "clamd configuration file not found, please manually configure"
        exit 1
    fi
    cp "$CLAMD_CONF" "$CLAMD_CONF.bak"

    sed -i -E 's|^#\s?LogFileMaxSize\s+.*|LogFileMaxSize 2M|' "$CLAMD_CONF"
    sed -i -E 's|^#\s?PidFile\s+.*|PidFile /run/clamd.scan/clamd.pid|' "$CLAMD_CONF"
    sed -i -E 's|^#\s?DatabaseDirectory\s+.*|DatabaseDirectory /var/lib/clamav|' "$CLAMD_CONF"
    sed -i -E 's|^#\s?LocalSocket\s+.*|LocalSocket /run/clamd.scan/clamd.sock|' "$CLAMD_CONF"
}

configure_freshclam() {
    echo -e "${GREEN}Configure freshclam...${NC}"
    
    FRESHCLAM_CONF=""
    if [ -f "/etc/freshclam.conf" ]; then
        FRESHCLAM_CONF="/etc/freshclam.conf"
    elif [ -f "/etc/clamav/freshclam.conf" ]; then
        FRESHCLAM_CONF="/etc/clamav/freshclam.conf"
    else
        echo "freshclam configuration file not found, please manually configure"
        exit 1
    fi
    cp "$FRESHCLAM_CONF" "$FRESHCLAM_CONF.bak"

    sed -i -E 's|^#\s?DatabaseDirectory\s+.*|DatabaseDirectory /var/lib/clamav|' "$FRESHCLAM_CONF"
    sed -i -E 's|^#\s?PidFile\s+.*|PidFile /var/run/freshclam.pid|' "$FRESHCLAM_CONF"
    sed -i '/^DatabaseMirror/d' "$FRESHCLAM_CONF"
    echo "DatabaseMirror database.clamav.net" | sudo tee -a "$FRESHCLAM_CONF"
    sed -i -E 's|^#\s?Checks\s+.*|Checks 12|' "$FRESHCLAM_CONF"
}

download_database() {
    systemctl stop clamav-freshclam
    echo -e "${GREEN}The virus database starts to download...${NC}"
    
    MAX_RETRIES=5
    RETRY_DELAY=60
    ATTEMPT=1
    
    while [ $ATTEMPT -le $MAX_RETRIES ]; do
        echo -e "${YELLOW}Try $ATTEMPT/$MAX_RETRIES: run freshclam...${NC}"
        
        if freshclam --verbose; then
            echo -e "${GREEN}Download successfully${NC}"
            return 0
        fi
        
        if [ $ATTEMPT -lt $MAX_RETRIES ]; then
            echo -e "${YELLOW}Download failed, wait $RETRY_DELAY seconds and try again...${NC}"
            sleep $RETRY_DELAY
        fi
        
        ATTEMPT=$((ATTEMPT+1))
    done
    
    echo -e "${RED}Error: Unable to download virus database after $MAX_RETRIES attempt${NC}" >&2
    exit 1
}

start_services() {
    echo -e "${GREEN}Start ClamAV...${NC}"
    
    case "$OS" in
        ubuntu|debian)
            systemctl enable --now clamav-daemon
            systemctl enable --now clamav-freshclam
            ;;
        centos|rhel|fedora)
            systemctl enable --now clamd@scan
            systemctl enable --now clamav-freshclam
            ;;
        alpine)
            rc-update add clamd boot
            rc-update add freshclam boot
            rc-service clamd start
            rc-service freshclam start
            ;;
        arch)
            systemctl enable --now clamav-daemon
            systemctl enable --now clamav-freshclam
            ;;
        *)
            echo -e "${YELLOW}The service cannot be started automatically. Please start manually!${NC}"
            ;;
    esac
    
   if ! command -v clamscan &> /dev/null; then
        echo -e "${RED}Install ClamAV failed${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}ClamAV is installed and started${NC}"
}

main() {
    detect_os
    install_clamav
    configure_clamd
    configure_freshclam
    download_database
    start_services
}

main "$@"