#!/usr/bin/env bash

set -u

SERVICE_NAME="socat-forward.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
SOCAT_BIN="/usr/bin/socat"

GREEN='\033[0;32m'
NC='\033[0m'

print_menu() {
    echo
    echo -e "${GREEN}==========================${NC}"
    echo -e "${GREEN}1) Setup forward${NC}"
    echo -e "${GREEN}2) Delete forward${NC}"
    echo -e "${GREEN}3) Exit${NC}"
    echo -e "${GREEN}==========================${NC}"
}

prepare() {
    if [ "$0" != "/usr/local/bin/socat_cascade" ]; then
        cp -f "$0" "/usr/local/bin/socat_cascade"
        chmod +x "/usr/local/bin/socat_cascade"
    fi
}

require_sudo() {
    if ! sudo -v >/dev/null 2>&1; then
        echo "Error: sudo access is required."
        exit 1
    fi
}

install_socat() {
    if command -v socat >/dev/null 2>&1; then
        echo "socat is already installed."
        return 0
    fi

    echo "socat is not installed. Installing..."
    require_sudo

    if sudo apt-get install -y socat >/dev/null 2>&1; then
        return 0
    else
        echo "Error: failed to install socat."
        return 1
    fi
}

delete_forward() {
    echo "Deleting forward..."

    require_sudo

    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        echo "Stopping ${SERVICE_NAME}..."
        sudo systemctl stop "${SERVICE_NAME}" >/dev/null 2>&1
    fi

    if systemctl is-enabled --quiet "${SERVICE_NAME}" 2>/dev/null; then
        echo "Disabling ${SERVICE_NAME}..."
        sudo systemctl disable "${SERVICE_NAME}" >/dev/null 2>&1
    else
        sudo systemctl disable "${SERVICE_NAME}" >/dev/null 2>&1 || true
    fi

    if [ -f "${SERVICE_FILE}" ]; then
        echo "Removing ${SERVICE_FILE}..."
        sudo rm -f "${SERVICE_FILE}"
    fi

    sudo systemctl daemon-reload >/dev/null 2>&1
    sudo systemctl reset-failed >/dev/null 2>&1 || true

    echo "Forward deleted."
}

setup_forward() {
    local TARGET_IP PORT IN_PORT OUT_PORT

    read -rp "Enter target IP: " TARGET_IP
    read -rp "Enter port: " PORT

    if [ -z "${TARGET_IP}" ] || [ -z "${PORT}" ]; then
        echo "Error: target IP and port must not be empty."
        return 1
    fi

    if ! [[ "${PORT}" =~ ^[0-9]+$ ]] || [ "${PORT}" -lt 1 ] || [ "${PORT}" -gt 65535 ]; then
        echo "Error: port must be a number between 1 and 65535."
        return 1
    fi

    IN_PORT="${PORT}"
    OUT_PORT="${PORT}"

    install_socat || return 1

    delete_forward

    echo "Creating ${SERVICE_FILE}..."
    require_sudo

    sudo tee "${SERVICE_FILE}" >/dev/null <<EOF
[Unit]
Description=UDP forward using socat
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=${SOCAT_BIN} -T15 udp-recvfrom:${IN_PORT},reuseaddr,fork udp-sendto:${TARGET_IP}:${OUT_PORT}
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload >/dev/null 2>&1

    if sudo systemctl enable --now "${SERVICE_NAME}" >/dev/null 2>&1; then
        echo "Forward is configured and service started."
        echo "Listening on UDP port ${IN_PORT} and forwarding to ${TARGET_IP}:${OUT_PORT}"
    else
        echo "Error: failed to enable/start ${SERVICE_NAME}."
        return 1
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
                delete_forward
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

prepare
main
