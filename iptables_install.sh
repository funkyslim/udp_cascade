#!/usr/bin/env bash

set -u

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

print_menu() {
    echo
    echo -e "${GREEN}==========================${NC}"
    echo -e "${GREEN}1) Setup forward${NC}"
	echo -e "${GREEN}2) Delete all iptables rules${NC}"
    echo -e "${GREEN}3) Exit${NC}"
    echo -e "${GREEN}==========================${NC}"
}

require_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}[ERROR] Run the script under root!${NC}"
        exit 1
    fi
}

prepare() {
    if [ "$0" != "/usr/local/bin/iptables_cascade" ]; then
        cp -f "$0" "/usr/local/bin/iptables_cascade"
        chmod +x "/usr/local/bin/iptables_cascade"
    fi

    if grep -Eq '^[[:space:]]*#?[[:space:]]*net\.ipv4\.ip_forward=' /etc/sysctl.conf; then
		sed -i 's/^[[:space:]]*#\?[[:space:]]*net\.ipv4\.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
	else
		echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
	fi

    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    fi

    if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    fi

    sysctl -p > /dev/null

    export DEBIAN_FRONTEND=noninteractive
    if ! dpkg -s iptables-persistent >/dev/null 2>&1; then
        apt-get update -y > /dev/null
        apt-get install -y iptables-persistent netfilter-persistent > /dev/null
    fi
}

delete_old_rules() {
    local TARGET_IP="$1"
    local PORT="$2"
	local PROTO="$3"
	
    iptables -t nat -D PREROUTING -p "$PROTO" --dport "$PORT" -j DNAT --to-destination "${TARGET_IP}:${PORT}" 2>/dev/null || true
    iptables -D FORWARD -p "$PROTO" -d "$TARGET_IP" --dport "$PORT" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -p "$PROTO" -s "$TARGET_IP" --sport "$PORT" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    iptables -t nat -D POSTROUTING -p "$PROTO" -d "$TARGET_IP" --dport "$PORT" -j MASQUERADE 2>/dev/null || true
}

apply_rules() {
    local TARGET_IP="$1"
    local PORT="$2"
	local PROTO="$3"

    delete_old_rules "$TARGET_IP" "$PORT" "$PROTO"

    iptables -t nat -A PREROUTING -p "$PROTO" --dport "$PORT" -j DNAT --to-destination "${TARGET_IP}:${PORT}"
    iptables -A FORWARD -p "$PROTO" -d "$TARGET_IP" --dport "$PORT" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT
    iptables -A FORWARD -p "$PROTO" -s "$TARGET_IP" --sport "$PORT" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -t nat -A POSTROUTING -p "$PROTO" -d "$TARGET_IP" --dport "$PORT" -j MASQUERADE
	
	if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        ufw allow "$PORT"/"$PROTO" >/dev/null
        sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
        ufw reload >/dev/null
    fi

    netfilter-persistent save > /dev/null
	
    echo
    echo "Forward configured:"
    echo "  any client -> this server:${PORT} -> ${TARGET_IP}:${PORT}"
    echo
    iptables -t nat -L PREROUTING -n -v --line-numbers
    iptables -L FORWARD -n -v --line-numbers
    iptables -t nat -L POSTROUTING -n -v --line-numbers
}

setup_forward() {
    local TARGET_IP
    local PORT

    read -rp "Enter target IP: " TARGET_IP
    read -rp "Enter UDP port to forward: " PORT

    apply_rules "$TARGET_IP" "$PORT" "udp"
}

delete_all_rules() {
    echo -e "\n${RED}!!! WARNING !!!${NC}"
    echo "This will reset ALL iptables configuration."
    read -p "Are you sure? (y/n): " confirm
    if [[ "$confirm" == "y" ]]; then
        iptables -P INPUT ACCEPT
        iptables -P FORWARD ACCEPT
        iptables -P OUTPUT ACCEPT
        iptables -t nat -F
        iptables -t mangle -F
        iptables -F
        iptables -X
        netfilter-persistent save > /dev/null
        echo -e "${GREEN}[OK] Configuration cleared.${NC}"
    fi
}

main() {
    while true; do
        print_menu
        read -rp "Select an option [1-3]: " choice

        case "${choice}" in
            1)
                setup_forward
                ;;
            2)
                delete_all_rules
                ;;
            3)
                echo "Exiting."
                exit 0
                ;;
            *)
                echo "Invalid option. Please choose 1, 2, or 3."
                ;;
        esac
    done
}

require_root
prepare
main