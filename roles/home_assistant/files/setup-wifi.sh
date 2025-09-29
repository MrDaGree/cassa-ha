#!/usr/bin/env bash
set -euo pipefail

# --- Functions ---
has_network() {
    ping -q -c1 -W1 8.8.8.8 &>/dev/null
}

wifi_setup() {
    echo "Scanning for Wi-Fi networks..."
    mapfile -t ssids < <(nmcli -t -f SSID dev wifi list | grep -v '^$' | sort -u)

    if [ ${#ssids[@]} -eq 0 ]; then
        echo "No Wi-Fi networks found. Try again."
        exit 1
    fi

    echo "Available Wi-Fi networks:"
    for i in "${!ssids[@]}"; do
        printf "%2d) %s\n" $((i+1)) "${ssids[$i]}"
    done

    read -rp "Select network number: " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#ssids[@]} )); then
        echo "Invalid choice."
        exit 1
    fi

    ssid="${ssids[$((choice-1))]}"
    read -rsp "Enter password for \"$ssid\": " password
    echo

    echo "Connecting to $ssid..."
    nmcli dev wifi connect "$ssid" password "$password" || {
        echo "Failed to connect to $ssid."
        exit 1
    }

    echo "Connected!"
}

# --- Main ---
if has_network; then
    echo "Network already available."
    exit 0
fi

wifi_setup

if has_network; then
    echo "Network setup successful."
    ip a s dev wlan0
    systemctl restart hassio-supervisor &
    lsblk
    growpart /dev/mmcblk0 2
    resize2fs /dev/mmcblk0p2
    lsblk
else
    echo "Still no network. Please troubleshoot manually."
    exit 1
fi
