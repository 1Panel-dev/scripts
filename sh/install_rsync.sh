#!/bin/bash
# Install and Configure Rsync
# Support Ubuntu/Debian/CentOS/RHEL/Alpine/Arch Linux

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
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

install_rsync() {
    echo -e "${GREEN}Detected system: $OS $VERSION${NC}"
    
    # Check if rsync is already installed
    if command -v rsync >/dev/null 2>&1; then
        echo -e "${YELLOW}Rsync is already installed: $(rsync --version | head -n1)${NC}"
        return 0
    fi

    echo -e "${BLUE}Installing rsync...${NC}"
    
    case "$OS" in
        ubuntu|debian)
            apt-get update
            apt-get install -y rsync
            ;;
        centos|rhel|fedora)
            if [ "$OS" = "rhel" ] && [ "${VERSION%%.*}" -ge 8 ]; then
                dnf install -y rsync
            else
                yum install -y rsync
            fi
            ;;
        alpine)
            apk add --no-cache rsync
            ;;
        arch)
            pacman -Sy --noconfirm rsync
            ;;
        *)
            echo -e "${RED}Unsupported system: $OS${NC}"
            exit 1
            ;;
    esac
    
    echo -e "${GREEN}Rsync installed successfully!${NC}"
}

configure_rsync() {
    echo -e "${GREEN}Configuring rsync...${NC}"
    
    RSYNCD_CONF="/etc/rsyncd.conf"
    RSYNCD_SECRETS="/etc/rsyncd.secrets"
    RSYNCD_MOTD="/etc/rsyncd.motd"
    
    # Create basic rsyncd.conf if it doesn't exist
    if [ ! -f "$RSYNCD_CONF" ]; then
        echo -e "${BLUE}Creating basic rsyncd.conf...${NC}"
        cat <<EOF > "$RSYNCD_CONF"
# Rsync daemon configuration
# Global settings
uid = nobody
gid = nobody
use chroot = yes
max connections = 4
pid file = /var/run/rsyncd.pid
exclude = lost+found/
transfer logging = yes
timeout = 600
ignore nonreadable = yes
dont compress = *.gz *.tgz *.zip *.z *.Z *.rpm *.deb *.bz2

# Example module (commented out)
#[backup]
#    path = /home/backup
#    comment = Backup Directory
#    read only = false
#    list = yes
#    uid = root
#    gid = root
#    auth users = backup
#    secrets file = /etc/rsyncd.secrets

EOF
        echo -e "${GREEN}Basic rsyncd.conf created at $RSYNCD_CONF${NC}"
    else
        echo -e "${YELLOW}rsyncd.conf already exists at $RSYNCD_CONF${NC}"
    fi
    
    # Create motd file
    if [ ! -f "$RSYNCD_MOTD" ]; then
        cat <<EOF > "$RSYNCD_MOTD"
Welcome to this rsync server.
EOF
        echo -e "${GREEN}Created rsyncd.motd at $RSYNCD_MOTD${NC}"
    fi
    
    # Create example secrets file (with restrictive permissions)
    if [ ! -f "$RSYNCD_SECRETS" ]; then
        cat <<EOF > "$RSYNCD_SECRETS"
# Format: username:password
# Example:
# backup:your_secure_password_here
EOF
        chmod 600 "$RSYNCD_SECRETS"
        echo -e "${GREEN}Created example rsyncd.secrets at $RSYNCD_SECRETS${NC}"
        echo -e "${YELLOW}Remember to set proper passwords in $RSYNCD_SECRETS${NC}"
    fi
}

setup_systemd_service() {
    echo -e "${BLUE}Setting up rsync daemon service...${NC}"
    
    if command -v systemctl >/dev/null 2>&1; then
        # Check if rsync service exists
        if systemctl list-unit-files | grep -q "^rsync.service"; then
            echo -e "${GREEN}Rsync systemd service already exists${NC}"
        else
            # Create systemd service file if it doesn't exist
            SYSTEMD_SERVICE="/etc/systemd/system/rsync.service"
            if [ ! -f "$SYSTEMD_SERVICE" ]; then
                cat <<EOF > "$SYSTEMD_SERVICE"
[Unit]
Description=Rsync daemon
After=network.target

[Service]
Type=notify
ExecStart=/usr/bin/rsync --daemon --no-detach
ExecReload=/bin/kill -HUP \$MAINPID
KillMode=process
Restart=on-failure
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF
                echo -e "${GREEN}Created systemd service file${NC}"
            fi
        fi
        
        # Reload systemd and enable service
        systemctl daemon-reload
        systemctl enable rsync
        echo -e "${GREEN}Rsync daemon service enabled${NC}"
    fi
}

setup_xinetd_service() {
    echo -e "${BLUE}Setting up rsync with xinetd...${NC}"
    
    # Install xinetd if not present
    case "$OS" in
        ubuntu|debian)
            if ! command -v xinetd >/dev/null 2>&1; then
                apt-get install -y xinetd
            fi
            ;;
        centos|rhel|fedora)
            if ! command -v xinetd >/dev/null 2>&1; then
                if [ "$OS" = "rhel" ] && [ "${VERSION%%.*}" -ge 8 ]; then
                    dnf install -y xinetd
                else
                    yum install -y xinetd
                fi
            fi
            ;;
        alpine)
            if ! command -v xinetd >/dev/null 2>&1; then
                apk add --no-cache xinetd
            fi
            ;;
        arch)
            if ! command -v xinetd >/dev/null 2>&1; then
                pacman -Sy --noconfirm xinetd
            fi
            ;;
    esac
    
    # Create xinetd configuration for rsync
    XINETD_RSYNC="/etc/xinetd.d/rsync"
    if [ ! -f "$XINETD_RSYNC" ]; then
        cat <<EOF > "$XINETD_RSYNC"
service rsync
{
        disable         = no
        socket_type     = stream
        wait            = no
        user            = root
        server          = /usr/bin/rsync
        server_args     = --daemon
        log_on_failure  += USERID
}
EOF
        echo -e "${GREEN}Created xinetd rsync configuration${NC}"
    fi
}

start_service() {
    echo -e "${GREEN}Starting rsync service...${NC}"
    
    case "$OS" in
        ubuntu|debian)
            if command -v systemctl >/dev/null 2>&1; then
                systemctl start rsync 2>/dev/null || {
                    echo -e "${YELLOW}Systemd service failed, trying xinetd...${NC}"
                    setup_xinetd_service
                    systemctl enable xinetd
                    systemctl start xinetd
                }
            else
                setup_xinetd_service
                service xinetd start
            fi
            ;;
        centos|rhel|fedora)
            if command -v systemctl >/dev/null 2>&1; then
                systemctl start rsync 2>/dev/null || {
                    echo -e "${YELLOW}Systemd service failed, trying xinetd...${NC}"
                    setup_xinetd_service
                    systemctl enable xinetd
                    systemctl start xinetd
                }
            else
                setup_xinetd_service
                service xinetd start
            fi
            ;;
        alpine)
            setup_xinetd_service
            rc-update add xinetd
            rc-service xinetd start
            ;;
        arch)
            if command -v systemctl >/dev/null 2>&1; then
                systemctl start rsync 2>/dev/null || {
                    echo -e "${YELLOW}Systemd service failed, trying xinetd...${NC}"
                    setup_xinetd_service
                    systemctl enable xinetd
                    systemctl start xinetd
                }
            fi
            ;;
        *)
            echo -e "${YELLOW}Service cannot be started automatically. Please start manually!${NC}"
            ;;
    esac
}

check_status() {
    echo -e "${BLUE}Checking rsync status...${NC}"
    
    # Check if rsync is installed
    if command -v rsync >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Rsync version: $(rsync --version | head -n1)${NC}"
    else
        echo -e "${RED}✗ Rsync not found${NC}"
        return 1
    fi
    
    # Check if daemon is running
    if pgrep -x rsync >/dev/null; then
        echo -e "${GREEN}✓ Rsync daemon is running${NC}"
    else
        echo -e "${YELLOW}! Rsync daemon is not running${NC}"
    fi
    
    # Check listening ports
    if command -v ss >/dev/null 2>&1; then
        if ss -tlnp | grep -q ":873"; then
            echo -e "${GREEN}✓ Rsync daemon listening on port 873${NC}"
        else
            echo -e "${YELLOW}! Rsync daemon not listening on port 873${NC}"
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -tlnp | grep -q ":873"; then
            echo -e "${GREEN}✓ Rsync daemon listening on port 873${NC}"
        else
            echo -e "${YELLOW}! Rsync daemon not listening on port 873${NC}"
        fi
    fi
    
    echo -e "${GREEN}Rsync installation completed!${NC}"
}

show_usage() {
    echo -e "${BLUE}Rsync Installation Script${NC}"
    echo ""
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --daemon-only    Install rsync daemon service only"
    echo "  --client-only    Install rsync client only (no daemon)"
    echo "  --help          Show this help message"
    echo ""
}

main() {
    local daemon_only=false
    local client_only=false
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --daemon-only)
                daemon_only=true
                shift
                ;;
            --client-only)
                client_only=true
                shift
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            *)
                echo -e "${RED}Unknown option: $1${NC}"
                show_usage
                exit 1
                ;;
        esac
    done
    
    echo -e "${BLUE}=== Rsync Installation Script ===${NC}"
    
    detect_os
    install_rsync
    
    if [ "$client_only" = false ]; then
        configure_rsync
        setup_systemd_service
        start_service
    fi
    
    check_status
}

main "$@"