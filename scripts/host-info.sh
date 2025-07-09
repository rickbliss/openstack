#!/usr/bin/env bash
# Usage: ./get-all-info.sh <host1> [host2 …]
if [ "$#" -lt 1 ]; then
  echo "Usage: $0 <host1> [host2 …]"
  exit 1
fi

for host in "$@"; do
  echo "===== $host ====="
  ssh -o ForwardX11=no -q -T "$host" bash --noprofile --norc <<'EOF'
# 1) Total memory slots (dmidecode Type 16)
printf "%s: Total memory slots available: " "$host"
sudo dmidecode -t 16 2>/dev/null | awk -F": " '/Number Of Devices/ { print $2; exit }'
echo

# 2) Detailed installed modules and empty slots (dmidecode Type 17)
echo "$host: Memory Modules:"
sudo dmidecode -t 17 2>/dev/null | awk -F": " '
  /^[[:space:]]*Memory Device/ { in_block=1; skip=0; size=""; type=""; speed=""; manu=""; part=""; next }
  in_block && /^[[:space:]]*Size:[[:space:]]/ {
    sub(/^[[:space:]]*Size:[[:space:]]/, "")
    if ($0 == "No Module Installed") { skip=1 } else size=$0
    next
  }
  in_block && /^[[:space:]]*Type:[[:space:]]/ {
    sub(/^[[:space:]]*Type:[[:space:]]/, "")
    type=$0
    next
  }
  in_block && /^[[:space:]]*Speed:[[:space:]]/ {
    sub(/^[[:space:]]*Speed:[[:space:]]/, "")
    speed=$0
    next
  }
  in_block && /^[[:space:]]*Manufacturer:[[:space:]]/ {
    sub(/^[[:space:]]*Manufacturer:[[:space:]]/, "")
    manu=$0
    next
  }
  in_block && /^[[:space:]]*Part Number:[[:space:]]/ {
    sub(/^[[:space:]]*Part Number:[[:space:]]/, "")
    part=$0
    next
  }
  /^[[:space:]]*$/ {
    if (in_block) {
      if (skip || size == "") {
        empty++
      } else {
        installed++
        printf "  Slot %d: Size=%s, Type=%s, Speed=%s, Manufacturer=%s, Model=%s\n", installed, size, type, speed, manu, part
      }
    }
    in_block=0
    next
  }
  END {
    if (in_block) {
      if (skip || size == "") {
        empty++
      } else {
        installed++
        printf "  Slot %d: Size=%s, Type=%s, Speed=%s, Manufacturer=%s, Model=%s\n", installed, size, type, speed, manu, part
      }
    }
    printf "%s: Total installed: %d\n", "'$host'", installed
    printf "%s: Empty slots: %d\n", "'$host'", empty
  }
'
echo

# 3) Memory Usage (excluding cache)
mem_perc=$(free -m | awk '/Mem/ { used_nocache = $2 - $4 - $6; printf "%.2f", used_nocache/$2*100 }')
echo "$host: Memory Usage (excluding cache): $mem_perc%"
echo

# 4) CPU Model and Info
echo "$host: CPU Information:"
cpu_info=$(lscpu | grep "Model name:" | sed 's/Model name:[[:space:]]*//')
cpu_sockets=$(lscpu | grep "Socket(s):" | awk '{print $2}')
cpu_cores=$(lscpu | grep "Core(s) per socket:" | awk '{print $4}')
cpu_threads=$(lscpu | grep "Thread(s) per core:" | awk '{print $4}')
total_cores=$((cpu_sockets * cpu_cores))
total_threads=$((cpu_sockets * cpu_cores * cpu_threads))
echo "  Model: $cpu_info"
echo "  Sockets: $cpu_sockets, Cores per socket: $cpu_cores, Threads per core: $cpu_threads"
echo "  Total cores: $total_cores, Total threads: $total_threads"
echo

# 5) All Storage Devices Information
echo "$host: Storage Devices:"
# Get all block devices (excluding loop, ram, etc.)
lsblk -dno NAME,SIZE,TYPE,VENDOR,MODEL,ROTA | grep -E '^[a-z]+[a-z0-9]*[[:space:]]+.*[[:space:]]+(disk|nvme)[[:space:]]' | while read name size type vendor model rota; do
  # Determine drive type
  if [[ $name =~ ^nvme ]]; then
    drive_type="NVMe SSD"
  elif [[ $rota -eq 0 ]]; then
    drive_type="SSD"
  else
    drive_type="HDD"
  fi
  
  # Get additional info for NVMe drives
  if [[ $name =~ ^nvme ]]; then
    # Try to get NVMe specific info
    nvme_info=$(nvme id-ctrl /dev/$name 2>/dev/null | grep -E '^(mn|sn|fr)' | tr '\n' ' ' || echo "")
    echo "  /dev/$name: $size $drive_type - $vendor $model $nvme_info"
  else
    # For SATA/SAS drives, try to get more details
    smart_info=""
    if command -v smartctl >/dev/null 2>&1; then
      smart_info=$(smartctl -i /dev/$name 2>/dev/null | grep -E '^(Device Model|Product|Rotation Rate):' | cut -d: -f2 | tr -d ' ' | tr '\n' ' ' || echo "")
    fi
    echo "  /dev/$name: $size $drive_type - $vendor $model $smart_info"
  fi
done

# Show which device contains the root filesystem
root_blk=$(findmnt -n -o SOURCE /)
root_base=$(basename "$root_blk")
if [[ $root_base =~ p[0-9]+$ ]]; then
  root_disk=${root_base%p*}
else
  root_disk=${root_base%%[0-9]*}
fi
echo "  Root filesystem is on: /dev/$root_disk"
echo

# 6) Root Filesystem Usage
df -h / | awk 'NR==2 { printf "%s: Root FS Usage: %s used / %s total (%s)\n", "'$host'", $3, $2, $5 }'
echo

# 7) Baseboard Info (dmidecode Type 2)
echo "$host: Baseboard (Type 2):"
sudo dmidecode -t 2
echo

# 8) Network Interfaces - Enhanced with logical grouping and MAC addresses
echo "$host: Network Interfaces:"

# Create temporary files for grouping
TEMP_DIR="/tmp/interface_info_$$"
mkdir -p "$TEMP_DIR"

# Physical interfaces
echo "" > "$TEMP_DIR/physical"
echo "" > "$TEMP_DIR/management"
echo "" > "$TEMP_DIR/storage" 
echo "" > "$TEMP_DIR/tenant"
echo "" > "$TEMP_DIR/virtual"
echo "" > "$TEMP_DIR/mgmt"
echo "" > "$TEMP_DIR/bond"
echo "" > "$TEMP_DIR/bridge"
echo "" > "$TEMP_DIR/ovs"
echo "" > "$TEMP_DIR/overlay"
echo "" > "$TEMP_DIR/vlan"
echo "" > "$TEMP_DIR/loopback"
echo "" > "$TEMP_DIR/other"

# Get all unique interfaces first
interfaces=$(ip -o link show | awk '{print $2}' | sed 's/:$//' | sed 's/@.*//' | sort -u)

# Process each interface
for iface in $interfaces; do
  # Get interface state
  state=$(ip -o link show "$iface" 2>/dev/null | awk '{print $3}' | tr -d '<>' | head -1)
  
  # Get MAC address - more robust extraction
  mac_addr=$(ip -o link show "$iface" 2>/dev/null | grep -o 'link/ether [a-f0-9:]*' | awk '{print $2}' | head -1)
  if [[ -z "$mac_addr" || "$mac_addr" == "00:00:00:00:00:00" ]]; then
    # Try alternative method
    mac_addr=$(cat "/sys/class/net/$iface/address" 2>/dev/null)
  fi
  if [[ -z "$mac_addr" || "$mac_addr" == "00:00:00:00:00:00" ]]; then
    mac_addr="(no MAC)"
  fi
  
  # Get IPv4 address if any
  ipv4_addr=$(ip -o -4 addr show "$iface" 2>/dev/null | awk '{print $4}' | head -1)
  
  # Get IPv6 address if any (for interfaces without IPv4)
  ipv6_addr=""
  if [[ -z "$ipv4_addr" ]]; then
    ipv6_addr=$(ip -o -6 addr show "$iface" 2>/dev/null | grep -v "::1/128" | awk '{print $4}' | head -1)
  fi
  
  # Use IPv4 if available, otherwise show IPv6 or "no IP"
  addr="$ipv4_addr"
  if [[ -z "$addr" ]]; then
    if [[ -n "$ipv6_addr" ]]; then
      addr="$ipv6_addr (IPv6)"
    else
      addr="(no IP)"
    fi
  fi
  
  # Get interface type and additional info
  iface_type=""
  speed=""
  duplex=""
  carrier=""
  
  # Check if interface exists in /sys/class/net/
  if [[ -d "/sys/class/net/$iface" ]]; then
    # Get carrier state
    if [[ -f "/sys/class/net/$iface/carrier" ]]; then
      carrier_state=$(cat "/sys/class/net/$iface/carrier" 2>/dev/null || echo "unknown")
      case $carrier_state in
        1) carrier="UP" ;;
        0) carrier="DOWN" ;;
        *) carrier="UNKNOWN" ;;
      esac
    fi
    
    # Get speed and duplex for physical interfaces
    if [[ -f "/sys/class/net/$iface/speed" ]] && [[ -f "/sys/class/net/$iface/duplex" ]]; then
      speed=$(cat "/sys/class/net/$iface/speed" 2>/dev/null || echo "unknown")
      duplex=$(cat "/sys/class/net/$iface/duplex" 2>/dev/null || echo "unknown")
      if [[ "$speed" != "unknown" && "$speed" -gt 0 ]]; then
        speed="${speed}Mbps"
      fi
    fi
    
    # Get interface type
    if [[ -f "/sys/class/net/$iface/type" ]]; then
      type_num=$(cat "/sys/class/net/$iface/type" 2>/dev/null)
      case $type_num in
        1) iface_type="Ethernet" ;;
        24) iface_type="Loopback" ;;
        772) iface_type="Loopback" ;;
        *) iface_type="Type:$type_num" ;;
      esac
    fi
  fi
  
  # Build interface info string with MAC address and hostname
  info_str="  $HOSTNAME: $iface"
  [[ -n "$mac_addr" ]] && info_str="$info_str (MAC: $mac_addr)"
  [[ -n "$addr" ]] && info_str="$info_str $addr"
  [[ -n "$state" ]] && info_str="$info_str [$state]"
  [[ -n "$carrier" && "$carrier" != "UNKNOWN" ]] && info_str="$info_str (Link: $carrier)"
  [[ -n "$speed" && "$speed" != "unknown" ]] && info_str="$info_str (Speed: $speed)"
  [[ -n "$duplex" && "$duplex" != "unknown" ]] && info_str="$info_str (Duplex: $duplex)"
  [[ -n "$iface_type" ]] && info_str="$info_str [$iface_type]"
  
  # Categorize interfaces
  case "$iface" in
    lo|lo:*)
      echo "$info_str" >> "$TEMP_DIR/loopback"
      ;;
    eth*|en*|em*|p[0-9]*|eno*|ens*)
      # Check for specific purposes in interface name
      if [[ "$iface" =~ mgmt|ipmi|bmc ]]; then
        echo "$info_str" >> "$TEMP_DIR/mgmt"
      elif [[ "$iface" =~ ceph ]]; then
        echo "$info_str" >> "$TEMP_DIR/storage"
      elif [[ "$iface" =~ tenant|overlay ]]; then
        echo "$info_str" >> "$TEMP_DIR/tenant"
      elif [[ "$iface" =~ host ]]; then
        echo "$info_str" >> "$TEMP_DIR/management"
      else
        echo "$info_str" >> "$TEMP_DIR/physical"
      fi
      ;;
    bond*)
      echo "$info_str" >> "$TEMP_DIR/bond"
      ;;
    br*|virbr*|docker*|xenbr*)
      echo "$info_str" >> "$TEMP_DIR/bridge"
      ;;
    ovs*)
      echo "$info_str" >> "$TEMP_DIR/ovs"
      ;;
    genev*|vxlan*)
      echo "$info_str" >> "$TEMP_DIR/overlay"
      ;;
    *.*)
      echo "$info_str" >> "$TEMP_DIR/vlan"
      ;;
    veth*|tap*|tun*|vnet*)
      echo "$info_str" >> "$TEMP_DIR/virtual"
      ;;
    *mgmt*|*ipmi*|*bmc*)
      echo "$info_str" >> "$TEMP_DIR/mgmt"
      ;;
    *)
      echo "$info_str" >> "$TEMP_DIR/other"
      ;;
  esac
done

# Display grouped interfaces
if [[ -s "$TEMP_DIR/physical" ]]; then
  echo "  Physical Interfaces:"
  cat "$TEMP_DIR/physical"
fi

if [[ -s "$TEMP_DIR/management" ]]; then
  echo "  Management/Host Interfaces:"
  cat "$TEMP_DIR/management"
fi

if [[ -s "$TEMP_DIR/storage" ]]; then
  echo "  Storage Network Interfaces:"
  cat "$TEMP_DIR/storage"
fi

if [[ -s "$TEMP_DIR/tenant" ]]; then
  echo "  Tenant/Overlay Network Interfaces:"
  cat "$TEMP_DIR/tenant"
fi

if [[ -s "$TEMP_DIR/mgmt" ]]; then
  echo "  Hardware Management Interfaces:"
  cat "$TEMP_DIR/mgmt"
fi

if [[ -s "$TEMP_DIR/bond" ]]; then
  echo "  Bond Interfaces:"
  cat "$TEMP_DIR/bond"
fi

if [[ -s "$TEMP_DIR/bridge" ]]; then
  echo "  Bridge Interfaces:"
  cat "$TEMP_DIR/bridge"
fi

if [[ -s "$TEMP_DIR/ovs" ]]; then
  echo "  Open vSwitch Interfaces:"
  cat "$TEMP_DIR/ovs"
fi

if [[ -s "$TEMP_DIR/overlay" ]]; then
  echo "  Overlay/Tunnel Interfaces:"
  cat "$TEMP_DIR/overlay"
fi

if [[ -s "$TEMP_DIR/vlan" ]]; then
  echo "  VLAN Interfaces:"
  cat "$TEMP_DIR/vlan"
fi

if [[ -s "$TEMP_DIR/virtual" ]]; then
  echo "  Virtual Interfaces:"
  cat "$TEMP_DIR/virtual"
fi

if [[ -s "$TEMP_DIR/loopback" ]]; then
  echo "  Loopback Interfaces:"
  cat "$TEMP_DIR/loopback"
fi

if [[ -s "$TEMP_DIR/other" ]]; then
  echo "  Other Interfaces:"
  cat "$TEMP_DIR/other"
fi

# Cleanup
rm -rf "$TEMP_DIR"

# Additional network info
echo ""
echo "  Network Summary:"
total_interfaces=$(ip link show | grep -c '^[0-9]')
active_interfaces=$(ip -o addr show | grep -c 'inet ')
ipv6_only_interfaces=$(ip -o addr show | grep -E 'inet6.*scope (global|link)' | grep -v 'inet ' | wc -l)
echo "    Total interfaces: $total_interfaces"
echo "    IPv4 configured interfaces: $active_interfaces"
echo "    IPv6-only interfaces: $ipv6_only_interfaces"

# Show routing table summary
default_route=$(ip route show default | head -1)
if [[ -n "$default_route" ]]; then
  echo "    $HOSTNAME: Default route: $default_route"
fi

EOF

  echo "Capturing netplan configuration for $host..."
  
  # Get netplan configuration and save to file
  ssh -o ForwardX11=no -q -T "$host" 'sudo netplan get 2>/dev/null' > "${host}-netplan.yml" 2>/dev/null
  
  # Check if the file has content
  if [ -s "${host}-netplan.yml" ]; then
    echo "✓ Netplan configuration saved to ${host}-netplan.yml"
  else
    # If empty, try to get error info and create explanatory file
    ssh -o ForwardX11=no -q -T "$host" 'sudo netplan get 2>&1' > "${host}-netplan.yml"
    if [ ! -s "${host}-netplan.yml" ]; then
      cat > "${host}-netplan.yml" << NETPLAN_EOF
# Netplan configuration not available for $host
# This could mean:
# - Netplan is not installed
# - No netplan configuration exists  
# - Insufficient permissions
# - System uses different network management (systemd-networkd, NetworkManager, etc.)
# - Netplan service is not running

# To check on the host directly, try:
# sudo netplan get
# systemctl status netplan
# ls -la /etc/netplan/
NETPLAN_EOF
    fi
    echo "⚠ Could not retrieve netplan configuration for $host (see ${host}-netplan.yml for details)"
  fi
  echo
done