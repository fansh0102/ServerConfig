#! /bin/sh
#
# set-mgmt-bmc-ip.sh
# Copyright (C) 2025 Tiger1218 <tiger1218@foxmail.com>
#
# Distributed under terms of the GNU AGPLv3 license.
#
# This script reads serial number, finds corresponding IPs in a mapping file,
# configures Netplan for the management IP, and sets the IPMI IP.

# --- Configuration ---
MAPPING_FILE="./mapping.txt" # IMPORTANT: Change this to your actual mapping file path
NETPLAN_CONFIG_DIR="/etc/netplan/"
NETPLAN_CONFIG_FILE_NAME="70-auto-sigdml-config.yaml" # A higher number ensures it's applied last
MANAGEMENT_INTERFACE="ens33"
# DNS_SERVERS="8.8.8.8,8.8.4.4"                    # Comma-separated DNS servers

# --- Functions ---

set -e


# Function to check for root privileges
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Error: This script must be run as root. Please use 'sudo'."
        exit 1
    fi
}

# Function to get the system serial number
get_serial_number() {
    SERIAL_NUMBER=$(dmidecode -s system-serial-number 2>/dev/null)
    if [[ -z "$SERIAL_NUMBER" ]]; then
        echo "Error: Could not retrieve serial number using dmidecode."
        echo "Please ensure dmidecode is installed and accessible."
        exit 1
    fi
    # Convert spaces to dashes
    SERIAL_NUMBER_CLEANED=$(echo "$SERIAL_NUMBER" | tr ' ' '-')
    echo "$SERIAL_NUMBER_CLEANED"
}

# Function to parse the mapping file
parse_mapping_file() {
    local sn="$1"
    local mapping_file="$2"
    local ipmi_ip=""
    local mgmt_ip=""

    if [[ ! -f "$mapping_file" ]]; then
        echo "Error: Mapping file not found at '$mapping_file'."
        exit 1
    fi

    while IFS=' ' read -r current_sn current_ipmi_ip current_mgmt_ip; do
        if [[ "$current_sn" == "$sn" ]]; then
            ipmi_ip="$current_ipmi_ip"
            mgmt_ip="$current_mgmt_ip"
            break
        fi
    done < "$mapping_file"

    if [[ -z "$ipmi_ip" || -z "$mgmt_ip" ]]; then
        echo "Error: Could not find IP addresses for serial number '$sn' in '$mapping_file'."
        exit 1
    fi

    echo "$ipmi_ip $mgmt_ip"
}

# Function to generate Netplan configuration
generate_netplan_config() {
    local mgmt_ip="$1"
    local interface_name="$2"
    local dns_servers="$3"

    # Extract network prefix for gateway assumption (e.g., 192.168.1)
    local gateway_prefix=$(echo "$mgmt_ip" | cut -d '.' -f 1-3)
    local default_gateway="${gateway_prefix}.254" # Assumes gateway is .254 of the subnet

    cat <<EOF
network:
  version: 2
  renderer: networkd
  
  ethernets:
    # 物理接口配置（不配置IP，用于bond）
    ens20f0np0:
      dhcp4: false
      dhcp6: false
    ens19f0np0:
      dhcp4: false  
      dhcp6: false
      
  bonds:
    # Bond接口配置
    bond0:
      interfaces:
        - ens20f0np0
        - ens19f0np0
      parameters:
        mode: 802.3ad  # 可选: balance-rr, active-backup, balance-xor, broadcast, 802.3ad, balance-tlb, balance-alb
        # primary: ens33       # 主接口
        mii-monitor-interval: 100
        up-delay: 200
        down-delay: 200
      dhcp4: false
      dhcp6: false
      
  vlans:
    # VLAN子接口配置
    bond0.1000:
      id: 1000
      link: bond0
      addresses:
        - ${mgmt_ip}/24
      routes:
        - to: default
          via: 10.0.0.254
      # nameservers:
      #   addresses:
      #     - 8.8.8.8
EOF
}

# Function to apply Netplan configuration
apply_netplan_config() {
    local netplan_content="$1"
    local config_path="$2"

    echo "$netplan_content" > "$config_path"
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to write Netplan configuration to '$config_path'."
        exit 1
    fi
    echo "Netplan configuration written to '$config_path'"

    echo "Applying Netplan configuration..."
    netplan apply
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to apply Netplan configuration. Check logs for details."
        exit 1
    fi
    echo "Netplan configuration applied successfully."
}

# Function to set IPMI IP
set_ipmi_ip() {
    local ipmi_ip="$1"

    echo "Setting IPMI IP to $ipmi_ip..."

    # Extract network prefix for gateway assumption (e.g., 192.168.1)
    local gateway_prefix=$(echo "$ipmi_ip" | cut -d '.' -f 1-3)
    local default_gateway="${gateway_prefix}.254" # Assumes gateway is .254 of the subnet

    # Set channel to static
    ipmitool lan set 1 ipsrc static
    if [[ $? -ne 0 ]]; then echo "Error: Failed to set IPMI channel to static."; exit 1; fi
    echo "IPMI: Set channel 1 to static."

    # Set IP address
    ipmitool lan set 1 ipaddr "$ipmi_ip"
    if [[ $? -ne 0 ]]; then echo "Error: Failed to set IPMI IP address."; exit 1; fi
    echo "IPMI: IP address set to $ipmi_ip."

    # Set Netmask (assuming /24, adjust as needed)
    ipmitool lan set 1 netmask 255.255.255.0
    if [[ $? -ne 0 ]]; then echo "Error: Failed to set IPMI netmask."; exit 1; fi
    echo "IPMI: Netmask set to 255.255.255.0."

    # Set Gateway
    ipmitool lan set 1 defgw ipaddr "$default_gateway"
    if [[ $? -ne 0 ]]; then echo "Error: Failed to set IPMI default gateway."; exit 1; fi
    echo "IPMI: Default gateway set to $default_gateway."

    echo "IPMI configuration complete."
}

# --- Main Script Logic ---
check_root

echo "Starting network configuration script..."

# 1. Get Serial Number
SERIAL_NUMBER=$(get_serial_number)
echo "System Serial Number: $SERIAL_NUMBER"

# 2. Parse Mapping File
read -r IPMI_IP MGMT_IP <<< $(parse_mapping_file "$SERIAL_NUMBER" "$MAPPING_FILE")
echo "Found: IPMI-IP=$IPMI_IP, MGMT-IP=$MGMT_IP"

# 3. Generate and Apply Netplan Config for Management IP
NETPLAN_CONTENT=$(generate_netplan_config "$MGMT_IP" "$MANAGEMENT_INTERFACE" "$DNS_SERVERS")
FULL_NETPLAN_PATH="${NETPLAN_CONFIG_DIR}${NETPLAN_CONFIG_FILE_NAME}"
apply_netplan_config "$NETPLAN_CONTENT" "$FULL_NETPLAN_PATH"

# 4. Configure IPMI IP
set_ipmi_ip "$IPMI_IP"

echo -e "\nNetwork configuration script completed successfully!"
