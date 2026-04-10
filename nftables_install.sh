#!/usr/bin/env bash

set -u

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

SCRIPT_PATH="/usr/local/bin/nftables_cascade"
NFT_NAT_FAMILY="ip"
NFT_NAT_TABLE="nat"
NFT_PREROUTING_CHAIN="prerouting"
NFT_POSTROUTING_CHAIN="postrouting"
NFT_FILTER_FAMILY="inet"
NFT_FILTER_TABLE="filter"
NFT_FORWARD_CHAIN="forward"

print_menu() {
  echo
  echo -e "${GREEN}==========================${NC}"
  echo -e "${GREEN}1) Setup forward${NC}"
  echo -e "${GREEN}2) Delete all nftables rules${NC}"
  echo -e "${GREEN}3) Exit${NC}"
  echo -e "${GREEN}==========================${NC}"
}

require_root() {
  if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERROR] Run the script under root!${NC}"
    exit 1
  fi
}

save_ruleset() {
  {
    echo "flush ruleset"
    nft list ruleset
  } > /etc/nftables.conf
}

ensure_nft_base() {
  nft list table "$NFT_NAT_FAMILY" "$NFT_NAT_TABLE" >/dev/null 2>&1 || \
    nft add table "$NFT_NAT_FAMILY" "$NFT_NAT_TABLE"

  nft list chain "$NFT_NAT_FAMILY" "$NFT_NAT_TABLE" "$NFT_PREROUTING_CHAIN" >/dev/null 2>&1 || \
    nft add chain "$NFT_NAT_FAMILY" "$NFT_NAT_TABLE" "$NFT_PREROUTING_CHAIN" '{ type nat hook prerouting priority dstnat; policy accept; }'

  nft list chain "$NFT_NAT_FAMILY" "$NFT_NAT_TABLE" "$NFT_POSTROUTING_CHAIN" >/dev/null 2>&1 || \
    nft add chain "$NFT_NAT_FAMILY" "$NFT_NAT_TABLE" "$NFT_POSTROUTING_CHAIN" '{ type nat hook postrouting priority srcnat; policy accept; }'

  nft list table "$NFT_FILTER_FAMILY" "$NFT_FILTER_TABLE" >/dev/null 2>&1 || \
    nft add table "$NFT_FILTER_FAMILY" "$NFT_FILTER_TABLE"

  nft list chain "$NFT_FILTER_FAMILY" "$NFT_FILTER_TABLE" "$NFT_FORWARD_CHAIN" >/dev/null 2>&1 || \
    nft add chain "$NFT_FILTER_FAMILY" "$NFT_FILTER_TABLE" "$NFT_FORWARD_CHAIN" '{ type filter hook forward priority filter; policy accept; }'
}

prepare() {
  if [ "$0" != "$SCRIPT_PATH" ]; then
    cp -f "$0" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
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

  if ! dpkg -s nftables >/dev/null 2>&1; then
    apt-get update -y > /dev/null
    apt-get install -y nftables > /dev/null
  fi

  systemctl enable nftables.service >/dev/null 2>&1 || true
  systemctl start nftables.service >/dev/null 2>&1 || true

  ensure_nft_base
  save_ruleset
}

rule_handle_by_comment() {
  local FAMILY="$1"
  local TABLE="$2"
  local CHAIN="$3"
  local COMMENT="$4"

  nft -a list chain "$FAMILY" "$TABLE" "$CHAIN" 2>/dev/null | \
    awk -v c="$COMMENT" 'index($0, c) && /handle/ { print $NF }'
}

delete_rules_by_comment() {
  local FAMILY="$1"
  local TABLE="$2"
  local CHAIN="$3"
  local COMMENT="$4"
  local HANDLE

  while read -r HANDLE; do
    [ -n "$HANDLE" ] || continue
    nft delete rule "$FAMILY" "$TABLE" "$CHAIN" handle "$HANDLE" 2>/dev/null || true
  done < <(rule_handle_by_comment "$FAMILY" "$TABLE" "$CHAIN" "$COMMENT")
}

delete_old_rules() {
  local TARGET_IP="$1"
  local PORT="$2"
  local PROTO="$3"

  delete_rules_by_comment "$NFT_NAT_FAMILY" "$NFT_NAT_TABLE" "$NFT_PREROUTING_CHAIN" \
    "udp_cascade dnat ${PROTO} ${PORT} -> ${TARGET_IP}:${PORT}"

  delete_rules_by_comment "$NFT_FILTER_FAMILY" "$NFT_FILTER_TABLE" "$NFT_FORWARD_CHAIN" \
    "udp_cascade fwd_in ${PROTO} ${PORT} -> ${TARGET_IP}"

  delete_rules_by_comment "$NFT_FILTER_FAMILY" "$NFT_FILTER_TABLE" "$NFT_FORWARD_CHAIN" \
    "udp_cascade fwd_out ${PROTO} ${PORT} <- ${TARGET_IP}"

  delete_rules_by_comment "$NFT_NAT_FAMILY" "$NFT_NAT_TABLE" "$NFT_POSTROUTING_CHAIN" \
    "udp_cascade masq ${PROTO} ${PORT} -> ${TARGET_IP}"
}

apply_rules() {
  local TARGET_IP="$1"
  local PORT="$2"
  local PROTO="$3"

  ensure_nft_base
  delete_old_rules "$TARGET_IP" "$PORT" "$PROTO"

  nft add rule "$NFT_NAT_FAMILY" "$NFT_NAT_TABLE" "$NFT_PREROUTING_CHAIN" \
    "$PROTO" dport "$PORT" counter dnat to "${TARGET_IP}:${PORT}" \
    comment "udp_cascade dnat ${PROTO} ${PORT} -> ${TARGET_IP}:${PORT}"

  nft add rule "$NFT_FILTER_FAMILY" "$NFT_FILTER_TABLE" "$NFT_FORWARD_CHAIN" \
    ip daddr "$TARGET_IP" "$PROTO" dport "$PORT" ct state new,established,related \
    counter accept comment "udp_cascade fwd_in ${PROTO} ${PORT} -> ${TARGET_IP}"

  nft add rule "$NFT_FILTER_FAMILY" "$NFT_FILTER_TABLE" "$NFT_FORWARD_CHAIN" \
    ip saddr "$TARGET_IP" "$PROTO" sport "$PORT" ct state established,related \
    counter accept comment "udp_cascade fwd_out ${PROTO} ${PORT} <- ${TARGET_IP}"

  nft add rule "$NFT_NAT_FAMILY" "$NFT_NAT_TABLE" "$NFT_POSTROUTING_CHAIN" \
    ip daddr "$TARGET_IP" "$PROTO" dport "$PORT" counter masquerade \
    comment "udp_cascade masq ${PROTO} ${PORT} -> ${TARGET_IP}"

  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    ufw allow "$PORT"/"$PROTO" >/dev/null
    sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
    ufw reload >/dev/null
  fi

  save_ruleset

  echo
  echo "Forward configured:"
  echo " any client -> this server:${PORT} -> ${TARGET_IP}:${PORT}"
  echo

  nft -a list chain "$NFT_NAT_FAMILY" "$NFT_NAT_TABLE" "$NFT_PREROUTING_CHAIN"
  echo
  nft -a list chain "$NFT_FILTER_FAMILY" "$NFT_FILTER_TABLE" "$NFT_FORWARD_CHAIN"
  echo
  nft -a list chain "$NFT_NAT_FAMILY" "$NFT_NAT_TABLE" "$NFT_POSTROUTING_CHAIN"
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
  echo "This will reset ALL nftables configuration."

  read -r -p "Are you sure? (y/n): " confirm

  if [[ "$confirm" == "y" ]]; then
    nft flush ruleset
    save_ruleset
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
