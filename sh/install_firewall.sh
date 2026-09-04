#!/usr/bin/env bash

# Install and configure a firewall backend supported by the detected system.

set -Eeuo pipefail
umask 077

OS=""
OS_LIKE=""
VERSION=""
VERSION_MAJOR="0"
OS_FAMILY=""
FIREWALL=""
RECOMMENDED_FIREWALL="iptables"
IPTABLES_DEPRECATED=false
TCP_INPUT=""
UDP_INPUT=""
STATE_DIR="${INSTALL_STATE_DIR:-/var/lib/1panel/firewall}"
declare -a AVAILABLE_FIREWALLS=()
declare -a TCP_PORTS=()
declare -a UDP_PORTS=()
TCP_PORT_COUNT=0
UDP_PORT_COUNT=0
COLOR_ENABLED=false

init_output() {
    if [[ -z "${NO_COLOR:-}" && ( "${FORCE_COLOR:-0}" == 1 || ( -t 1 && "${TERM:-}" != dumb ) ) ]]; then
        COLOR_ENABLED=true
    fi
}

log() {
    local level="$1"; shift
    local color=""
    if [[ "$COLOR_ENABLED" == true ]]; then
        case "$level" in
            INFO) color=$'\033[0;32m' ;;
            SUCCESS) color=$'\033[1;32m' ;;
            WARN) color=$'\033[0;33m' ;;
            ERROR) color=$'\033[0;31m' ;;
            DEBUG) color=$'\033[0;36m' ;;
        esac
    fi
    local reset=""
    [[ -n "$color" ]] && reset=$'\033[0m'
    printf '%b[%s]%b %s\n' "$color" "$level" "$reset" "$*"
}

on_error() {
    local rc=$?
    trap - ERR
    log ERROR "command failed: rc=$rc line=$1 command=$2"
    if [[ "$FIREWALL" == firewalld ]]; then
        systemctl --no-pager --full status firewalld.service || true
        journalctl --no-pager -u firewalld.service -n 80 || true
    elif [[ "$FIREWALL" == ufw ]] && command -v ufw >/dev/null 2>&1; then
        ufw status verbose || true
    elif [[ "$FIREWALL" == nftables ]] && command -v nft >/dev/null 2>&1; then
        nft list table inet onepanel || true
    elif [[ "$FIREWALL" == iptables ]] && command -v iptables >/dev/null 2>&1; then
        iptables -S ONEPANEL_INPUT || true
    fi
    log ERROR "configuration failed"
    exit "$rc"
}

run() {
    log INFO "running: $(printf '%q ' "$@")"
    "$@"
}

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  -h, --help            Show this help

This installer is interactive. It shows only the firewall backends supported
by the detected system, then prompts for TCP and UDP ports.
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                usage
                exit 0
                ;;
            *)
                log ERROR "unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

detect_os() {
    [[ $EUID -eq 0 ]] || { log ERROR "this installer must run as root"; exit 1; }
    [[ -r /etc/os-release ]] || { log ERROR "/etc/os-release is missing"; exit 1; }
    # shellcheck disable=SC1091
    . /etc/os-release
    OS="${ID:-}"; OS_LIKE="${ID_LIKE:-}"; VERSION="${VERSION_ID:-unknown}"
    VERSION_MAJOR="${VERSION%%.*}"
    [[ "$VERSION_MAJOR" =~ ^[0-9]+$ ]] || VERSION_MAJOR=0
    case "$OS" in
        ubuntu|debian|linuxmint|pop)
            OS_FAMILY="debian"
            ;;
        rhel|centos|rocky|almalinux|fedora|ol|amzn)
            OS_FAMILY="rhel"
            ;;
        *)
            if [[ " $OS_LIKE " == *" debian "* ]]; then
                OS_FAMILY="debian"
            elif [[ " $OS_LIKE " == *" rhel "* || " $OS_LIKE " == *" fedora "* ]]; then
                OS_FAMILY="rhel"
            else
                log ERROR "unsupported system: os=$OS id_like=${OS_LIKE:-none}"
                exit 1
            fi
            ;;
    esac
    if [[ "$OS_FAMILY" == debian ]]; then
        AVAILABLE_FIREWALLS=(iptables nftables ufw)
    elif (( VERSION_MAJOR >= 9 )); then
        AVAILABLE_FIREWALLS=(nftables firewalld iptables)
        IPTABLES_DEPRECATED=true
    else
        AVAILABLE_FIREWALLS=(iptables nftables firewalld)
    fi
    RECOMMENDED_FIREWALL="${AVAILABLE_FIREWALLS[0]}"
    log INFO "detected os=$OS version=$VERSION family=$OS_FAMILY recommended_firewall=$RECOMMENDED_FIREWALL"
}

select_firewall() {
    local choice=""
    local index

    [[ -t 0 ]] || { log ERROR "this installer requires an interactive terminal"; exit 1; }
    printf '\nAvailable firewall backends for %s %s:\n' "$OS" "$VERSION"
    for index in "${!AVAILABLE_FIREWALLS[@]}"; do
        if (( index == 0 )); then
            printf '  %d) %s (recommended)\n' "$((index + 1))" "${AVAILABLE_FIREWALLS[$index]}"
        elif [[ "${AVAILABLE_FIREWALLS[$index]}" == iptables && "$IPTABLES_DEPRECATED" == true ]]; then
            printf '  %d) %s (deprecated on this system)\n' "$((index + 1))" "${AVAILABLE_FIREWALLS[$index]}"
        else
            printf '  %d) %s\n' "$((index + 1))" "${AVAILABLE_FIREWALLS[$index]}"
        fi
    done
    read -r -p "Select a firewall [1]: " choice
    choice="${choice:-1}"
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#AVAILABLE_FIREWALLS[@]} )); then
        log ERROR "invalid firewall selection: $choice"
        exit 1
    fi
    FIREWALL="${AVAILABLE_FIREWALLS[$((choice - 1))]}"
    log INFO "selected firewall=$FIREWALL available=${AVAILABLE_FIREWALLS[*]}"
}

append_unique() {
    local value="$1"
    local array_name="$2"
    local index

    case "$array_name" in
        TCP_PORTS)
            for ((index = 0; index < TCP_PORT_COUNT; index++)); do
                if [[ "${TCP_PORTS[$index]}" == "$value" ]]; then
                    return 0
                fi
            done
            TCP_PORTS+=("$value")
            ((TCP_PORT_COUNT += 1))
            ;;
        UDP_PORTS)
            for ((index = 0; index < UDP_PORT_COUNT; index++)); do
                if [[ "${UDP_PORTS[$index]}" == "$value" ]]; then
                    return 0
                fi
            done
            UDP_PORTS+=("$value")
            ((UDP_PORT_COUNT += 1))
            ;;
        *)
            log ERROR "unknown port array: $array_name"
            exit 1
            ;;
    esac
}

validate_and_add_ports() {
    local protocol="$1"
    local input="$2"
    local token start end
    for token in $input; do
        if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start="${BASH_REMATCH[1]}"; end="${BASH_REMATCH[2]}"
            if (( start < 1 || end > 65535 || start > end )); then
                log ERROR "invalid $protocol port range: $token"
                exit 1
            fi
        elif [[ "$token" =~ ^[0-9]+$ ]]; then
            if (( token < 1 || token > 65535 )); then
                log ERROR "invalid $protocol port: $token"
                exit 1
            fi
        else
            log ERROR "invalid $protocol port token: $token"
            exit 1
        fi
        if [[ "$protocol" == tcp ]]; then
            append_unique "$token" TCP_PORTS
        else
            append_unique "$token" UDP_PORTS
        fi
    done
}

collect_ports() {
    [[ -t 0 ]] || { log ERROR "this installer requires an interactive terminal"; exit 1; }
    read -r -p "TCP ports to allow (optional, for example: 22 80 443 39000-40000): " TCP_INPUT
    read -r -p "UDP ports to allow (press Enter to skip): " UDP_INPUT

    validate_and_add_ports tcp "$TCP_INPUT"
    validate_and_add_ports udp "$UDP_INPUT"

    local ssh_port=""
    if command -v sshd >/dev/null 2>&1; then
        ssh_port="$(sshd -T 2>/dev/null | awk '$1 == "port" && !found { print $2; found=1 }')"
    fi
    if [[ -n "$ssh_port" ]]; then
        append_unique "$ssh_port" TCP_PORTS
        log INFO "ensuring SSH port $ssh_port remains allowed"
    else
        log WARN "unable to determine the SSH daemon port; verify remote access before enabling the firewall"
    fi

    if (( TCP_PORT_COUNT == 0 && UDP_PORT_COUNT == 0 )); then
        log ERROR "no valid firewall ports were provided"
        exit 1
    fi
    log INFO "requested tcp_ports=${TCP_PORTS[*]:-none} udp_ports=${UDP_PORTS[*]:-none}"
}

install_firewall() {
    local pkg=""
    if [[ "$OS_FAMILY" == debian ]]; then
        export DEBIAN_FRONTEND=noninteractive
        case "$FIREWALL" in
            iptables)
                if command -v iptables >/dev/null 2>&1 && command -v netfilter-persistent >/dev/null 2>&1; then
                    log INFO "iptables and its persistence service are already installed"
                    return
                fi
                run apt-get update
                run apt-get install -y --no-install-recommends iptables iptables-persistent
                ;;
            nftables)
                if command -v nft >/dev/null 2>&1; then
                    log INFO "nftables is already installed"
                    return
                fi
                run apt-get update
                run apt-get install -y --no-install-recommends nftables
                ;;
            ufw)
                if command -v ufw >/dev/null 2>&1; then
                    log INFO "UFW is already installed"
                    return
                fi
                run apt-get update
                run apt-get install -y --no-install-recommends ufw
                ;;
        esac
        return
    fi

    pkg="$(command -v dnf || command -v yum || true)"
    [[ -n "$pkg" ]] || { log ERROR "dnf/yum is unavailable"; exit 1; }
    case "$FIREWALL" in
        iptables)
            if command -v iptables >/dev/null 2>&1 && systemctl cat iptables.service >/dev/null 2>&1; then
                log INFO "iptables and its persistence service are already installed"
                return
            fi
            if (( VERSION_MAJOR >= 9 )) || [[ "$OS" == fedora ]]; then
                run "$pkg" install -y iptables-nft iptables-nft-services
            else
                run "$pkg" install -y iptables-services
            fi
            ;;
        nftables)
            if command -v nft >/dev/null 2>&1; then
                log INFO "nftables is already installed"
                return
            fi
            run "$pkg" install -y nftables
            ;;
        firewalld)
            if command -v firewall-cmd >/dev/null 2>&1; then
                log INFO "firewalld is already installed"
                return
            fi
            run "$pkg" install -y firewalld
            ;;
    esac
}

unit_exists() {
    systemctl cat "$1" >/dev/null 2>&1
}

stop_and_disable_unit() {
    local unit="$1"
    unit_exists "$unit" || return 0
    if systemctl is-active --quiet "$unit"; then
        log WARN "stopping conflicting firewall service: $unit"
        run systemctl stop "$unit"
    fi
    if systemctl is-enabled --quiet "$unit"; then
        log WARN "disabling conflicting firewall service: $unit"
        run systemctl disable "$unit"
    fi
}

ufw_is_active() {
    command -v ufw >/dev/null 2>&1 || return 1
    ufw status | awk 'NR == 1 { active=($0 == "Status: active") } END { exit(active ? 0 : 1) }'
}

remove_managed_iptables_rules() {
    local binary state_file original_policy managed_chain_found
    for binary in iptables ip6tables; do
        command -v "$binary" >/dev/null 2>&1 || continue
        managed_chain_found=false
        if "$binary" -nL ONEPANEL_INPUT >/dev/null 2>&1; then
            managed_chain_found=true
            while "$binary" -C INPUT -j ONEPANEL_INPUT >/dev/null 2>&1; do
                run "$binary" -D INPUT -j ONEPANEL_INPUT
            done
            run "$binary" -F ONEPANEL_INPUT
            run "$binary" -X ONEPANEL_INPUT
        fi
        state_file="$STATE_DIR/${binary}-input-policy"
        original_policy=""
        if [[ -r "$state_file" ]]; then
            read -r original_policy < "$state_file"
        elif [[ "$managed_chain_found" == true ]]; then
            original_policy="ACCEPT"
        fi
        if [[ "$original_policy" == ACCEPT || "$original_policy" == DROP ]]; then
            run "$binary" -P INPUT "$original_policy"
        fi
        if [[ -e "$state_file" ]]; then
            rm -f "$state_file"
        fi
    done
}

remove_managed_nftables_rules() {
    if command -v nft >/dev/null 2>&1 && nft list table inet onepanel >/dev/null 2>&1; then
        run nft delete table inet onepanel
    fi
}

disable_conflicting_firewalls() {
    local unit
    case "$FIREWALL" in
        iptables)
            for unit in nftables.service firewalld.service; do stop_and_disable_unit "$unit"; done
            ;;
        nftables)
            for unit in iptables.service ip6tables.service netfilter-persistent.service firewalld.service; do stop_and_disable_unit "$unit"; done
            ;;
        ufw)
            for unit in iptables.service ip6tables.service netfilter-persistent.service nftables.service firewalld.service; do stop_and_disable_unit "$unit"; done
            ;;
        firewalld)
            for unit in iptables.service ip6tables.service netfilter-persistent.service nftables.service; do stop_and_disable_unit "$unit"; done
            ;;
    esac

    if [[ "$FIREWALL" != ufw ]] && ufw_is_active; then
        log WARN "disabling active UFW before enabling $FIREWALL"
        run ufw --force disable
    fi
    [[ "$FIREWALL" == iptables ]] || remove_managed_iptables_rules
    [[ "$FIREWALL" == nftables ]] || remove_managed_nftables_rules
}

iptables_rule() {
    local binary="$1"
    shift
    if ! "$binary" -C ONEPANEL_INPUT "$@" >/dev/null 2>&1; then
        run "$binary" -A ONEPANEL_INPUT "$@"
    fi
}

remember_iptables_input_policy() {
    local binary="$1"
    local state_file="$STATE_DIR/${binary}-input-policy"
    local policy
    [[ -e "$state_file" ]] && return 0
    policy="$("$binary" -S INPUT | awk '$1 == "-P" && $2 == "INPUT" && !found { print $3; found=1 }')"
    if [[ "$policy" != ACCEPT && "$policy" != DROP ]]; then
        log ERROR "unable to determine the current $binary INPUT policy"
        exit 1
    fi
    run mkdir -p "$STATE_DIR"
    printf '%s\n' "$policy" > "$state_file"
    chmod 600 "$state_file"
    log INFO "saved original $binary INPUT policy: $policy"
}

configure_iptables_family() {
    local binary="$1"
    local icmp_protocol="$2"
    local port normalized

    remember_iptables_input_policy "$binary"
    if ! "$binary" -nL ONEPANEL_INPUT >/dev/null 2>&1; then
        run "$binary" -N ONEPANEL_INPUT
    else
        run "$binary" -F ONEPANEL_INPUT
    fi
    if ! "$binary" -C INPUT -j ONEPANEL_INPUT >/dev/null 2>&1; then
        run "$binary" -I INPUT 1 -j ONEPANEL_INPUT
    fi
    iptables_rule "$binary" -i lo -j ACCEPT
    iptables_rule "$binary" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables_rule "$binary" -p "$icmp_protocol" -j ACCEPT
    for port in "${TCP_PORTS[@]+"${TCP_PORTS[@]}"}"; do
        normalized="${port/-/:}"
        iptables_rule "$binary" -p tcp -m tcp --dport "$normalized" -j ACCEPT
    done
    for port in "${UDP_PORTS[@]+"${UDP_PORTS[@]}"}"; do
        normalized="${port/-/:}"
        iptables_rule "$binary" -p udp -m udp --dport "$normalized" -j ACCEPT
    done
    iptables_rule "$binary" -j RETURN
    run "$binary" -P INPUT DROP
}

save_command_output() {
    local output_file="$1"
    shift
    local temp_file
    temp_file="$(mktemp)"
    "$@" > "$temp_file"
    run install -m 600 "$temp_file" "$output_file"
    rm -f "$temp_file"
}

configure_iptables() {
    local ipv6_configured=false
    command -v iptables >/dev/null 2>&1 || { log ERROR "iptables command is unavailable after installation"; exit 1; }

    configure_iptables_family iptables icmp
    if command -v ip6tables >/dev/null 2>&1 && ip6tables -S INPUT >/dev/null 2>&1; then
        configure_iptables_family ip6tables ipv6-icmp
        ipv6_configured=true
    else
        log WARN "IPv6 netfilter is unavailable; skipping ip6tables rules"
    fi

    if [[ "$OS_FAMILY" == debian ]]; then
        run netfilter-persistent save
        run systemctl enable netfilter-persistent.service
    else
        save_command_output /etc/sysconfig/iptables iptables-save
        run systemctl enable iptables.service
        if [[ "$ipv6_configured" == true ]]; then
            save_command_output /etc/sysconfig/ip6tables ip6tables-save
            run systemctl enable ip6tables.service
        fi
    fi
    iptables -nL ONEPANEL_INPUT
    [[ "$ipv6_configured" == false ]] || ip6tables -nL ONEPANEL_INPUT
}

configure_nftables() {
    local main_config
    local managed_config
    local port

    if [[ "$OS_FAMILY" == debian ]]; then
        main_config="/etc/nftables.conf"
        managed_config="/etc/nftables.d/1panel-firewall.nft"
    else
        main_config="/etc/sysconfig/nftables.conf"
        managed_config="/etc/sysconfig/nftables/1panel-firewall.nft"
    fi
    run mkdir -p "${managed_config%/*}"

    if ! nft list table inet onepanel >/dev/null 2>&1; then
        run nft add table inet onepanel
    fi
    if ! nft list chain inet onepanel input >/dev/null 2>&1; then
        run nft add chain inet onepanel input '{ type filter hook input priority -10; policy drop; }'
    else
        run nft flush chain inet onepanel input
    fi
    run nft add rule inet onepanel input iifname lo accept
    run nft add rule inet onepanel input ct state established,related accept
    run nft add rule inet onepanel input meta l4proto '{ icmp, ipv6-icmp }' accept
    for port in "${TCP_PORTS[@]+"${TCP_PORTS[@]}"}"; do
        run nft add rule inet onepanel input tcp dport "$port" accept
    done
    for port in "${UDP_PORTS[@]+"${UDP_PORTS[@]}"}"; do
        run nft add rule inet onepanel input udp dport "$port" accept
    done

    save_command_output "$managed_config" nft list table inet onepanel
    touch "$main_config"
    if ! grep -Fqx "include \"$managed_config\"" "$main_config"; then
        printf '\ninclude "%s"\n' "$managed_config" >> "$main_config"
    fi
    run systemctl enable nftables.service
    nft list table inet onepanel
}

configure_ufw() {
    local port normalized
    for port in "${TCP_PORTS[@]+"${TCP_PORTS[@]}"}"; do
        normalized="${port/-/:}"
        run ufw allow "$normalized/tcp"
    done
    for port in "${UDP_PORTS[@]+"${UDP_PORTS[@]}"}"; do
        normalized="${port/-/:}"
        run ufw allow "$normalized/udp"
    done
    run ufw --force enable
    if ! ufw_is_active; then
        log ERROR "UFW is not active after enable"
        exit 1
    fi
    ufw status verbose
}

configure_firewalld() {
    run systemctl enable firewalld.service
    local port zone
    if systemctl is-active --quiet firewalld.service; then
        zone="$(firewall-cmd --get-default-zone)"
        [[ -n "$zone" ]] || { log ERROR "unable to determine the firewalld default zone"; exit 1; }
        for port in "${TCP_PORTS[@]+"${TCP_PORTS[@]}"}"; do
            if firewall-cmd --zone="$zone" --permanent --query-port="$port/tcp" >/dev/null; then
                log INFO "firewalld rule already exists in $zone: $port/tcp"
            else
                run firewall-cmd --zone="$zone" --permanent --add-port="$port/tcp"
            fi
        done
        for port in "${UDP_PORTS[@]+"${UDP_PORTS[@]}"}"; do
            if firewall-cmd --zone="$zone" --permanent --query-port="$port/udp" >/dev/null; then
                log INFO "firewalld rule already exists in $zone: $port/udp"
            else
                run firewall-cmd --zone="$zone" --permanent --add-port="$port/udp"
            fi
        done
        run firewall-cmd --reload
    else
        command -v firewall-offline-cmd >/dev/null 2>&1 || {
            log ERROR "firewall-offline-cmd is required to add rules safely before first start"
            exit 1
        }
        zone="$(firewall-offline-cmd --get-default-zone)"
        [[ -n "$zone" ]] || { log ERROR "unable to determine the firewalld default zone"; exit 1; }
        for port in "${TCP_PORTS[@]+"${TCP_PORTS[@]}"}"; do
            if firewall-offline-cmd --zone="$zone" --query-port="$port/tcp" >/dev/null; then
                log INFO "firewalld offline rule already exists in $zone: $port/tcp"
            else
                run firewall-offline-cmd --zone="$zone" --add-port="$port/tcp"
            fi
        done
        for port in "${UDP_PORTS[@]+"${UDP_PORTS[@]}"}"; do
            if firewall-offline-cmd --zone="$zone" --query-port="$port/udp" >/dev/null; then
                log INFO "firewalld offline rule already exists in $zone: $port/udp"
            else
                run firewall-offline-cmd --zone="$zone" --add-port="$port/udp"
            fi
        done
        run systemctl start firewalld.service
    fi
    systemctl is-active --quiet firewalld.service || { log ERROR "firewalld is not active"; exit 1; }
    log INFO "firewalld $zone zone: $(firewall-cmd --zone="$zone" --list-all)"
}

main() {
    init_output
    trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
    log INFO "starting firewall installer"
    parse_args "$@"
    detect_os
    select_firewall
    collect_ports
    log SUCCESS "firewall input validation and preflight checks completed"
    install_firewall
    log SUCCESS "$FIREWALL package installation completed"
    disable_conflicting_firewalls
    case "$FIREWALL" in
        iptables) configure_iptables ;;
        nftables) configure_nftables ;;
        ufw) configure_ufw ;;
        firewalld) configure_firewalld ;;
    esac
    log SUCCESS "$FIREWALL rule configuration and activation checks completed"
    log SUCCESS "$FIREWALL configuration completed successfully"
}

if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]:-}" == "$0" ]]; then
    main "$@"
fi
