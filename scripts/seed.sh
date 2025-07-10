#!/bin/bash
set -e
# OpenStack Cloud Seeding Script
# This script sets up common OpenStack resources including images, flavors, networks, routers, and volume types
# Usage: ./seed_openstack.sh [setup|cleanup|status|testvm]
#source /opt/kolla-venv/bin/activate
#source kolla-ansible post-deploy -i /etc/kolla/multinode


# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/openstack_seed.log"
STATE_FILE="${SCRIPT_DIR}/openstack_seed_state.json"
IMAGES_DIR="${SCRIPT_DIR}/images"

# Network Configuration
declare -A NETWORKS=(
    ["ProviderLAN"]="flat:physnet1:192.168.1.0/24:192.168.1.200:192.168.1.253:192.168.1.1:192.168.1.1:external"
    ["Admin-GenPop"]="tenant::10.69.0.0/24:10.69.0.100:10.69.0.200:10.69.0.1:10.69.0.1:internal"
)

# Router Configuration
ROUTER_NAME="Admin-GenPop-router"
ROUTER_EXTERNAL_NETWORK="ProviderLAN"
ROUTER_EXTERNAL_IP="192.168.1.10"
ROUTER_INTERNAL_NETWORK="Admin-GenPop"

# Image Configuration
declare -A IMAGES=(
    ["ubuntu-24.10"]="https://cloud-images.ubuntu.com/oracular/current/oracular-server-cloudimg-amd64.img"
    ["ubuntu-24.04"]="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
    ["ubuntu-22.04"]="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
    ["centos-10"]="https://cloud.centos.org/centos/10-stream/x86_64/images/CentOS-Stream-GenericCloud-10-latest.x86_64.qcow2"
    ["centos-9"]="https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-x86_64-9-latest.x86_64.qcow2"
)

# Flavor Configuration (OpenStack standard flavors)
declare -A FLAVORS=(
    ["m1.tiny"]="1:512:1"      # vcpus:ram_mb:disk_gb
    ["m1.small"]="1:2048:20"
    ["m1.medium"]="2:4096:40"
    ["m1.large"]="4:8192:80"
    ["m1.xlarge"]="8:16384:160"
)

# Volume Type Configuration
declare -A VOLUME_TYPES=(
    ["SSD"]="ssd-rbd"
    ["HDD"]="hdd-rbd"
)

# Security Group Configuration
SECURITY_GROUP_NAME="common-client-access"

# Test VM Configuration
TESTVM_PREFIX="testvm"
TESTVM_FLAVOR="m1.small"
TESTVM_NETWORKS=("ProviderLAN" "Admin-GenPop")
TESTVM_KEY="ricki"

# Logging function
log() {
    local level=$1
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$LOG_FILE"
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check prerequisites
check_prerequisites() {
    log "INFO" "Checking prerequisites..."
    
    if ! command_exists openstack; then
        log "ERROR" "OpenStack CLI not found. Please install python-openstackclient"
        exit 1
    fi
    
    if ! command_exists wget; then
        log "ERROR" "wget not found. Please install wget"
        exit 1
    fi
    
    if ! command_exists jq; then
        log "ERROR" "jq not found. Please install jq for JSON processing"
        exit 1
    fi
    
    if ! command_exists qemu-img; then
        log "ERROR" "qemu-img not found. Please install qemu-utils or qemu-img"
        exit 1
    fi
    
    # Check if OpenStack credentials are sourced
    if [[ -z "$OS_AUTH_URL" ]]; then
        log "ERROR" "OpenStack credentials not found. Please source your openrc file first"
        exit 1
    fi
    
    log "INFO" "Prerequisites check passed"
}

# Initialize state tracking
init_state() {
    if [[ ! -f "$STATE_FILE" ]]; then
        echo '{"images":[],"flavors":[],"networks":[],"subnets":[],"routers":[],"security_groups":[],"test_vms":[],"quotas_updated":[],"volume_types":[]}' > "$STATE_FILE"
    fi
    
    # Update image properties for existing images
    for img in $(openstack image list -f value -c ID); do
        echo "Updating properties on image $img..."
        openstack image set \
            --property hw_scsi_model=virtio-scsi \
            --property hw_disk_bus=scsi \
            --property hw_qemu_guest_agent=yes \
            --property os_require_quiesce=yes \
            "$img"
    done
}

# Create volume types
create_volume_types() {
    log "INFO" "Creating volume types..."
    
    # Create SSD volume type
    if openstack volume type show "SSD" >/dev/null 2>&1; then
        log "INFO" "Volume type 'SSD' already exists"
    else
        log "INFO" "Creating SSD volume type"
        local ssd_type_id=$(openstack volume type create SSD --public -f value -c id)
        if [[ -n "$ssd_type_id" ]]; then
            openstack volume type set --property volume_backend_name=ssd-rbd SSD
            log "INFO" "Successfully created SSD volume type (ID: $ssd_type_id)"
            add_to_state "volume_types" "$ssd_type_id" "SSD"
        else
            log "ERROR" "Failed to create SSD volume type"
        fi
    fi
    
    # Create HDD volume type
    if openstack volume type show "HDD" >/dev/null 2>&1; then
        log "INFO" "Volume type 'HDD' already exists"
    else
        log "INFO" "Creating HDD volume type"
        local hdd_type_id=$(openstack volume type create HDD --public -f value -c id)
        if [[ -n "$hdd_type_id" ]]; then
            openstack volume type set --property volume_backend_name=hdd-rbd HDD
            log "INFO" "Successfully created HDD volume type (ID: $hdd_type_id)"
            add_to_state "volume_types" "$hdd_type_id" "HDD"
        else
            log "ERROR" "Failed to create HDD volume type"
        fi
    fi
    
    # Update DEFAULT volume type to use ssd-rbd
    if openstack volume type show "__DEFAULT__" >/dev/null 2>&1; then
        log "INFO" "Updating __DEFAULT__ volume type to use ssd-rbd backend"
        openstack volume type set --property volume_backend_name=ssd-rbd __DEFAULT__
        log "INFO" "Successfully updated __DEFAULT__ volume type"
    else
        log "WARNING" "__DEFAULT__ volume type not found - this may be normal depending on your OpenStack configuration"
    fi
}

# Create security group
create_security_group() {
    # Check if security group already exists
    if openstack security group show "$SECURITY_GROUP_NAME" >/dev/null 2>&1; then
        log "INFO" "Security group '$SECURITY_GROUP_NAME' already exists"
        return 0
    fi
    
    log "INFO" "Creating security group: $SECURITY_GROUP_NAME"
    local sg_id=$(openstack security group create \
        --description "Common client access rules - ICMP, SSH, RDP" \
        "$SECURITY_GROUP_NAME" \
        -f value -c id)
    
    if [[ -n "$sg_id" ]]; then
        log "INFO" "Successfully created security group: $SECURITY_GROUP_NAME (ID: $sg_id)"
        add_to_state "security_groups" "$sg_id" "$SECURITY_GROUP_NAME"
        
        # Add rules to security group
        add_security_group_rules "$sg_id"
    else
        log "ERROR" "Failed to create security group: $SECURITY_GROUP_NAME"
        return 1
    fi
}

# Add security group rules
add_security_group_rules() {
    local sg_id=$1
    
    log "INFO" "Adding security group rules to $SECURITY_GROUP_NAME"
    
    # Allow all ICMP
    openstack security group rule create \
        --protocol icmp \
        --ingress \
        "$sg_id" >/dev/null 2>&1
    log "INFO" "Added ICMP rule"
    
    # Allow SSH (port 22)
    openstack security group rule create \
        --protocol tcp \
        --dst-port 22 \
        --ingress \
        "$sg_id" >/dev/null 2>&1
    log "INFO" "Added SSH rule (port 22)"
    
    # Allow RDP (port 3389)
    openstack security group rule create \
        --protocol tcp \
        --dst-port 3389 \
        --ingress \
        "$sg_id" >/dev/null 2>&1
    log "INFO" "Added RDP rule (port 3389)"
    
    # Allow all egress (usually default, but let's be explicit)
    openstack security group rule create \
        --protocol any \
        --egress \
        "$sg_id" >/dev/null 2>&1 || true
    log "INFO" "Added egress rule"
}

# Set unlimited quotas
set_unlimited_quotas() {
    log "INFO" "Setting unlimited quotas for compute and volume resources..."
    
    # Get current project ID
    project_id=$(openstack project show -c id admin -f value)
    if [[ -z "$project_id" ]]; then
        log "ERROR" "Could not determine project ID"
        return 1
    fi
    
    # Set compute quotas to unlimited (-1)
    log "INFO" "Setting compute quotas to unlimited for project: $project_id"
    if openstack quota set --cores -1 --instances -1 --ram -1 "$project_id" 2>/dev/null; then
        log "INFO" "Successfully set compute quotas (cores, instances, ram) to unlimited"
        add_to_state "quotas_updated" "$project_id" "compute"
    else
        log "WARNING" "Failed to set compute quotas - continuing anyway"
    fi
    
    # Set volume quotas to unlimited (-1)
    log "INFO" "Setting volume quotas to unlimited for project: $project_id"
    if openstack quota set --volumes -1 --gigabytes -1 --snapshots -1 "$project_id" 2>/dev/null; then
        log "INFO" "Successfully set volume quotas (volumes, gigabytes, snapshots) to unlimited"
        add_to_state "quotas_updated" "$project_id" "volume"
    else
        log "WARNING" "Failed to set volume quotas - continuing anyway"
    fi
    
    # Set network quotas to unlimited (-1) if neutron is available
    log "INFO" "Setting network quotas to unlimited for project: $project_id"
    if openstack quota set --networks -1 --subnets -1 --ports -1 --routers -1 --floating-ips -1 --security-groups -1 --security-group-rules -1 "$project_id" 2>/dev/null; then
        log "INFO" "Successfully set network quotas to unlimited"
        add_to_state "quotas_updated" "$project_id" "network"
    else
        log "WARNING" "Failed to set network quotas - continuing anyway"
    fi
    
    # Display current quotas for verification
    log "INFO" "Quota setting completed, continuing with resource creation..."
}

# Add resource to state
add_to_state() {
    local resource_type=$1
    local resource_id=$2
    local resource_name=$3
    
    local temp_file=$(mktemp)
    jq --arg type "$resource_type" --arg id "$resource_id" --arg name "$resource_name" \
       '.[$type] += [{"id": $id, "name": $name}]' "$STATE_FILE" > "$temp_file"
    mv "$temp_file" "$STATE_FILE"
}

# Get resources from state
get_from_state() {
    local resource_type=$1
    jq -r ".${resource_type}[] | .id" "$STATE_FILE" 2>/dev/null || true
}

# Create images directory
create_images_dir() {
    if [[ ! -d "$IMAGES_DIR" ]]; then
        log "INFO" "Creating images directory: $IMAGES_DIR"
        mkdir -p "$IMAGES_DIR"
    fi
}

# Download image if not exists
download_image() {
    local name=$1
    local url=$2
    local filename=$(basename "$url")
    local filepath="${IMAGES_DIR}/${filename}"
    
    if [[ -f "$filepath" ]]; then
        log "INFO" "Image already exists: $filepath"
        return 0
    fi
    
    log "INFO" "Downloading $name from $url"
    wget -O "$filepath" "$url"
    
    if [[ $? -eq 0 ]]; then
        log "INFO" "Successfully downloaded: $filepath"
    else
        log "ERROR" "Failed to download: $url"
        return 1
    fi
}

# Convert image from qcow2 to raw format
convert_image() {
    local name=$1
    local url=$2
    local filename=$(basename "$url")
    local qcow2_filepath="${IMAGES_DIR}/${filename}"
    local raw_filename="${filename%.*}.raw"
    local raw_filepath="${IMAGES_DIR}/${raw_filename}"
    
    # Check if raw image already exists
    if [[ -f "$raw_filepath" ]]; then
        log "INFO" "Raw image already exists: $raw_filepath"
        # Verify it's actually a raw image
        local file_type=$(file "$raw_filepath" | grep -o "raw disk image" || echo "unknown")
        log "INFO" "File type verification: $file_type"
        return 0
    fi
    
    # Check if qcow2 source exists
    if [[ ! -f "$qcow2_filepath" ]]; then
        log "ERROR" "Source qcow2 image not found: $qcow2_filepath"
        return 1
    fi
    
    log "INFO" "Converting $name from qcow2 to raw format..."
    log "INFO" "Source: $qcow2_filepath"
    log "INFO" "Target: $raw_filepath"
    
    # Verify source is qcow2
    local source_type=$(qemu-img info "$qcow2_filepath" | grep "file format:" | awk '{print $3}')
    log "INFO" "Source file format detected: $source_type"
    
    # Convert image using qemu-img with verbose output
    log "INFO" "Running: qemu-img convert -f qcow2 -O raw '$qcow2_filepath' '$raw_filepath'"
    if qemu-img convert -f qcow2 -O raw "$qcow2_filepath" "$raw_filepath"; then
        log "INFO" "Conversion completed successfully"
        
        # Verify the converted file
        if [[ -f "$raw_filepath" ]]; then
            local target_type=$(qemu-img info "$raw_filepath" | grep "file format:" | awk '{print $3}')
            log "INFO" "Target file format verified: $target_type"
            
            # Show file sizes for verification
            local qcow2_size=$(du -h "$qcow2_filepath" | cut -f1)
            local raw_size=$(du -h "$raw_filepath" | cut -f1)
            log "INFO" "Image sizes - qcow2: $qcow2_size, raw: $raw_size"
            
            if [[ "$target_type" == "raw" ]]; then
                log "INFO" "Successfully converted $name to raw format"
                return 0
            else
                log "ERROR" "Conversion verification failed - target is not raw format: $target_type"
                return 1
            fi
        else
            log "ERROR" "Converted file not found after conversion: $raw_filepath"
            return 1
        fi
    else
        log "ERROR" "qemu-img convert command failed for $name"
        return 1
    fi
}

# Convert all downloaded images to raw format
convert_all_images() {
    log "INFO" "Converting all downloaded images to raw format..."
    
    local conversion_failed=0
    
    for name in "${!IMAGES[@]}"; do
        url="${IMAGES[$name]}"
        log "INFO" "Processing conversion for: $name"
        
        if ! convert_image "$name" "$url"; then
            log "ERROR" "Failed to convert image: $name"
            conversion_failed=1
        fi
    done
    
    if [[ $conversion_failed -eq 1 ]]; then
        log "ERROR" "Some image conversions failed. Raw format is required for upload."
        log "ERROR" "Please check the conversion errors above and resolve them before proceeding."
        return 1
    else
        log "INFO" "All image conversions completed successfully"
        return 0
    fi
}
upload_image() {
    local name=$1
    local url=$2
    local filename=$(basename "$url")
    local filepath="${IMAGES_DIR}/${filename}"
    
    # Check if image already exists in OpenStack
    if openstack image show "$name" >/dev/null 2>&1; then
        log "INFO" "Image '$name' already exists in OpenStack"
        return 0
    fi
    
    log "INFO" "Uploading image: $name"
    
    # Upload with progress display
    openstack image create \
        --file "$filepath" \
        --disk-format qcow2 \
        --container-format bare \
        --public \
        --progress \
        "$name"
    
    # Get the image ID separately
    local image_id=$(openstack image show "$name" -f value -c id 2>/dev/null)
    
    if [[ -n "$image_id" ]]; then
        log "INFO" "Successfully uploaded image: $name (ID: $image_id)"
        add_to_state "images" "$image_id" "$name"
    else
        log "ERROR" "Failed to upload image: $name"
        return 1
    fi
}

# Create flavor
create_flavor() {
    local name=$1
    local spec=$2
    local vcpus=$(echo "$spec" | cut -d: -f1)
    local ram=$(echo "$spec" | cut -d: -f2)
    local disk=$(echo "$spec" | cut -d: -f3)
    
    # Check if flavor already exists
    if openstack flavor show "$name" >/dev/null 2>&1; then
        log "INFO" "Flavor '$name' already exists"
        return 0
    fi
    
    log "INFO" "Creating flavor: $name (${vcpus}vCPUs, ${ram}MB RAM, ${disk}GB disk)"
    local flavor_id=$(openstack flavor create \
        --vcpus "$vcpus" \
        --ram "$ram" \
        --disk "$disk" \
        --public \
        "$name" \
        -f value -c id)
    
    if [[ -n "$flavor_id" ]]; then
        log "INFO" "Successfully created flavor: $name (ID: $flavor_id)"
        add_to_state "flavors" "$flavor_id" "$name"
    else
        log "ERROR" "Failed to create flavor: $name"
        return 1
    fi
}

# Create network
create_network() {
    local network_name=$1
    local network_config=$2
    
    # Parse network configuration
    local network_type=$(echo "$network_config" | cut -d: -f1)
    local physical_network=$(echo "$network_config" | cut -d: -f2)
    local subnet_cidr=$(echo "$network_config" | cut -d: -f3)
    local pool_start=$(echo "$network_config" | cut -d: -f4)
    local pool_end=$(echo "$network_config" | cut -d: -f5)
    local dns_server=$(echo "$network_config" | cut -d: -f6)
    local gateway_ip=$(echo "$network_config" | cut -d: -f7)
    local network_scope=$(echo "$network_config" | cut -d: -f8)
    
    # Check if network already exists
    if openstack network show "$network_name" >/dev/null 2>&1; then
        log "INFO" "Network '$network_name' already exists"
        return 0
    fi
    
    log "INFO" "Creating network: $network_name (type: $network_type, scope: $network_scope)"
    
    # Build network creation command as array to handle spaces properly
    local create_cmd=("openstack" "network" "create")
    
    if [[ "$network_scope" == "external" ]]; then
        create_cmd+=("--external" "--share")
    else
        create_cmd+=("--internal")
    fi
    
    if [[ "$network_type" == "flat" ]]; then
        create_cmd+=("--provider-network-type" "flat")
        if [[ -n "$physical_network" ]]; then
            create_cmd+=("--provider-physical-network" "$physical_network")
        fi
    elif [[ "$network_type" == "vlan" ]]; then
        local vlan_id=$(echo "$network_config" | cut -d: -f9)
        create_cmd+=("--provider-network-type" "vlan")
        if [[ -n "$physical_network" ]]; then
            create_cmd+=("--provider-physical-network" "$physical_network")
        fi
        if [[ -n "$vlan_id" ]]; then
            create_cmd+=("--provider-segment" "$vlan_id")
        fi
    elif [[ "$network_type" == "local" ]]; then
        create_cmd+=("--provider-network-type" "local")
    elif [[ "$network_type" == "tenant" ]]; then
        # Tenant networks don't need provider network type - they use the default (usually vxlan)
        log "DEBUG" "Creating tenant network - using default network type"
    fi
    
    create_cmd+=("$network_name" "-f" "value" "-c" "id")
    
    log "DEBUG" "Executing: ${create_cmd[*]}"
    local network_id=$("${create_cmd[@]}")
    
    if [[ -n "$network_id" ]]; then
        log "INFO" "Successfully created network: $network_name (ID: $network_id)"
        add_to_state "networks" "$network_id" "$network_name"
        
        # Create subnet
        create_subnet "$network_id" "$network_name" "$subnet_cidr" "$pool_start" "$pool_end" "$dns_server" "$gateway_ip"
    else
        log "ERROR" "Failed to create network: $network_name"
        return 1
    fi
}

# Create subnet
create_subnet() {
    local network_id=$1
    local network_name=$2
    local subnet_cidr=$3
    local pool_start=$4
    local pool_end=$5
    local dns_server=$6
    local gateway_ip=$7
    local subnet_name="${network_name}-subnet"
    
    log "INFO" "Creating subnet: $subnet_name"
    local subnet_id=$(openstack subnet create \
        --network "$network_id" \
        --subnet-range "$subnet_cidr" \
        --allocation-pool "start=${pool_start},end=${pool_end}" \
        --dns-nameserver "$dns_server" \
        --gateway "$gateway_ip" \
        "$subnet_name" \
        -f value -c id)
    
    if [[ -n "$subnet_id" ]]; then
        log "INFO" "Successfully created subnet: $subnet_name (ID: $subnet_id)"
        add_to_state "subnets" "$subnet_id" "$subnet_name"
    else
        log "ERROR" "Failed to create subnet: $subnet_name"
        return 1
    fi
}

# Create router with SNAT enabled
create_router() {
    # Check if router already exists
    if openstack router show "$ROUTER_NAME" >/dev/null 2>&1; then
        log "INFO" "Router '$ROUTER_NAME' already exists"
        
        # Check if it has the correct external IP
        local current_ip=$(openstack router show "$ROUTER_NAME" -f json | jq -r '.external_gateway_info.external_fixed_ips[0].ip_address' 2>/dev/null)
        if [[ "$current_ip" != "$ROUTER_EXTERNAL_IP" ]]; then
            log "INFO" "Updating router external IP from $current_ip to $ROUTER_EXTERNAL_IP"
            # Get external network ID
            local external_network_id=$(openstack network show "$ROUTER_EXTERNAL_NETWORK" -f value -c id 2>/dev/null)
            if [[ -n "$external_network_id" ]]; then
                openstack router set \
                    --external-gateway "$external_network_id" \
                    --fixed-ip ip-address="$ROUTER_EXTERNAL_IP" \
                    "$ROUTER_NAME"
                log "INFO" "Router external IP updated to: $ROUTER_EXTERNAL_IP"
            fi
        fi
        return 0
    fi
    
    log "INFO" "Creating router: $ROUTER_NAME"
    
    # Get external network ID
    local external_network_id=$(openstack network show "$ROUTER_EXTERNAL_NETWORK" -f value -c id 2>/dev/null)
    if [[ -z "$external_network_id" ]]; then
        log "ERROR" "External network '$ROUTER_EXTERNAL_NETWORK' not found"
        return 1
    fi
    
    # Create router with external gateway and fixed IP
    local router_id=$(openstack router create \
        --external-gateway "$external_network_id" \
        --fixed-ip ip-address="$ROUTER_EXTERNAL_IP" \
        --enable-snat \
        "$ROUTER_NAME" \
        -f value -c id)
    
    if [[ -n "$router_id" ]]; then
        log "INFO" "Successfully created router: $ROUTER_NAME (ID: $router_id) with external IP: $ROUTER_EXTERNAL_IP"
        add_to_state "routers" "$router_id" "$ROUTER_NAME"
        
        # Add internal network interface
        add_router_interface "$router_id"
    else
        log "ERROR" "Failed to create router: $ROUTER_NAME"
        return 1
    fi
}

# Add router interface to internal network
add_router_interface() {
    local router_id=$1
    
    # Get internal subnet ID
    local internal_subnet_id=$(openstack subnet show "${ROUTER_INTERNAL_NETWORK}-subnet" -f value -c id 2>/dev/null)
    if [[ -z "$internal_subnet_id" ]]; then
        log "ERROR" "Internal subnet '${ROUTER_INTERNAL_NETWORK}-subnet' not found"
        return 1
    fi
    
    log "INFO" "Adding router interface to subnet: ${ROUTER_INTERNAL_NETWORK}-subnet"
    if openstack router add subnet "$router_id" "$internal_subnet_id" >/dev/null 2>&1; then
        log "INFO" "Successfully added router interface to subnet: ${ROUTER_INTERNAL_NETWORK}-subnet"
    else
        log "ERROR" "Failed to add router interface to subnet: ${ROUTER_INTERNAL_NETWORK}-subnet"
        return 1
    fi
}

# Setup function
setup() {
    log "INFO" "Starting OpenStack cloud seeding..."
    
    check_prerequisites
    init_state
    create_images_dir
    
    # Source the OpenRC file if it exists
    if [[ -f "public-openrc.sh" ]]; then
        log "INFO" "Sourcing public-openrc.sh"
        source public-openrc.sh
    fi
    
    # Set unlimited quotas first
    log "INFO" "Setting unlimited quotas..."
    set_unlimited_quotas
    
    # Create volume types
    log "INFO" "Creating volume types..."
    create_volume_types
    
    # Download and upload images
    log "INFO" "Processing images..."
    for name in "${!IMAGES[@]}"; do
        url="${IMAGES[$name]}"
        download_image "$name" "$url"
    done
    
    # Convert all images to raw format
    log "INFO" "Converting images to raw format..."
    if ! convert_all_images; then
        log "ERROR" "Image conversion failed. Cannot proceed with upload."
        log "ERROR" "All images must be in raw format for upload to OpenStack."
        exit 1
    fi
    
    # Upload all images
    log "INFO" "Uploading images to OpenStack..."
    for name in "${!IMAGES[@]}"; do
        url="${IMAGES[$name]}"
        upload_image "$name" "$url"
    done
    
    # Create flavors
    log "INFO" "Creating flavors..."
    for name in "${!FLAVORS[@]}"; do
        spec="${FLAVORS[$name]}"
        create_flavor "$name" "$spec"
    done
    
    # Create network and subnet
    log "INFO" "Creating network infrastructure..."
    for network_name in "${!NETWORKS[@]}"; do
        network_config="${NETWORKS[$network_name]}"
        create_network "$network_name" "$network_config"
    done
    
    # Create router
    log "INFO" "Creating router..."
    create_router
    
    # Create security group
    log "INFO" "Creating security group..."
    create_security_group
    
    log "INFO" "OpenStack cloud seeding completed successfully!"
    log "INFO" "State file: $STATE_FILE"
    log "INFO" "Log file: $LOG_FILE"
}

# Cleanup function
cleanup() {
    log "INFO" "Starting OpenStack cloud cleanup..."
    
    if [[ ! -f "$STATE_FILE" ]]; then
        log "WARNING" "State file not found. Nothing to cleanup."
        return 0
    fi
    
    # Delete test VMs first
    log "INFO" "Deleting test VMs..."
    for vm_id in $(get_from_state "test_vms"); do
        if openstack server show "$vm_id" >/dev/null 2>&1; then
            openstack server delete "$vm_id"
            log "INFO" "Deleted test VM: $vm_id"
        fi
    done
    
    # Wait for VMs to be deleted before proceeding
    sleep 5
    
    # Delete router interfaces and routers
    log "INFO" "Deleting routers..."
    for router_id in $(get_from_state "routers"); do
        if openstack router show "$router_id" >/dev/null 2>&1; then
            # Remove internal interface first
            local internal_subnet_id=$(openstack subnet show "${ROUTER_INTERNAL_NETWORK}-subnet" -f value -c id 2>/dev/null)
            if [[ -n "$internal_subnet_id" ]]; then
                openstack router remove subnet "$router_id" "$internal_subnet_id" 2>/dev/null || true
                log "INFO" "Removed router interface from subnet: ${ROUTER_INTERNAL_NETWORK}-subnet"
            fi
            
            # Clear external gateway
            openstack router unset --external-gateway "$router_id" 2>/dev/null || true
            log "INFO" "Cleared router external gateway"
            
            # Delete router
            openstack router delete "$router_id"
            log "INFO" "Deleted router: $router_id"
        fi
    done
    
    # Delete subnets
    log "INFO" "Deleting subnets..."
    for subnet_id in $(get_from_state "subnets"); do
        if openstack subnet show "$subnet_id" >/dev/null 2>&1; then
            openstack subnet delete "$subnet_id"
            log "INFO" "Deleted subnet: $subnet_id"
        fi
    done
    
    # Delete networks
    log "INFO" "Deleting networks..."
    for network_id in $(get_from_state "networks"); do
        if openstack network show "$network_id" >/dev/null 2>&1; then
            openstack network delete "$network_id"
            log "INFO" "Deleted network: $network_id"
        fi
    done
    
    # Delete flavors
    log "INFO" "Deleting flavors..."
    for flavor_id in $(get_from_state "flavors"); do
        if openstack flavor show "$flavor_id" >/dev/null 2>&1; then
            openstack flavor delete "$flavor_id"
            log "INFO" "Deleted flavor: $flavor_id"
        fi
    done
    
    # Delete security groups
    log "INFO" "Deleting security groups..."
    for sg_id in $(get_from_state "security_groups"); do
        if openstack security group show "$sg_id" >/dev/null 2>&1; then
            openstack security group delete "$sg_id"
            log "INFO" "Deleted security group: $sg_id"
        fi
    done
    
    # Delete volume types (but not __DEFAULT__)
    log "INFO" "Deleting volume types..."
    for vt_id in $(get_from_state "volume_types"); do
        if openstack volume type show "$vt_id" >/dev/null 2>&1; then
            local vt_name=$(openstack volume type show "$vt_id" -f value -c name 2>/dev/null)
            # Don't delete the __DEFAULT__ volume type
            if [[ "$vt_name" != "__DEFAULT__" ]]; then
                openstack volume type delete "$vt_id"
                log "INFO" "Deleted volume type: $vt_name (ID: $vt_id)"
            else
                log "INFO" "Skipping deletion of __DEFAULT__ volume type"
            fi
        fi
    done
    
    # Delete images
    log "INFO" "Deleting images..."
    
    # Track which images we've already deleted to avoid duplicates
    local deleted_images=()
    
    # First, delete images tracked in state file
    for image_id in $(get_from_state "images"); do
        if openstack image show "$image_id" >/dev/null 2>&1; then
            local image_name=$(openstack image show "$image_id" -f value -c name 2>/dev/null)
            openstack image delete "$image_id"
            log "INFO" "Deleted image: $image_name (ID: $image_id)"
            deleted_images+=("$image_name")
        fi
    done
    
    # Also delete any remaining images with names matching our image list (in case they're not in state)
    log "INFO" "Cleaning up any remaining images created by this script..."
    for image_name in "${!IMAGES[@]}"; do
        # Skip if we already deleted this image
        if [[ " ${deleted_images[@]} " =~ " ${image_name} " ]]; then
            continue
        fi
        
        if openstack image show "$image_name" >/dev/null 2>&1; then
            local image_status=$(openstack image show "$image_name" -f value -c status 2>/dev/null)
            log "INFO" "Found orphaned image '$image_name' with status: $image_status - deleting"
            openstack image delete "$image_name"
            log "INFO" "Deleted orphaned image: $image_name"
        fi
    done
    
    # Remove state file
    rm -f "$STATE_FILE"
    log "INFO" "Cleanup completed successfully!"
}

# Test VM functions
get_available_hypervisors() {
    openstack hypervisor list -f value -c "Hypervisor Hostname" 2>/dev/null | head -10
}

get_random_image() {
    local images=($(openstack image list --status active -f value -c Name | grep -E "(ubuntu|centos)" | head -5))
    if [[ ${#images[@]} -eq 0 ]]; then
        echo "ubuntu-24.04"  # fallback
    else
        echo "${images[$((RANDOM % ${#images[@]}))]}"
    fi
}

launch_test_vm() {
    local hypervisor=$1
    local network_name=$2
    local vm_name="${TESTVM_PREFIX}-${hypervisor}-${network_name}"
    local image_name=$(get_random_image)
    
    log "INFO" "Launching test VM: $vm_name on hypervisor: $hypervisor with image: $image_name on network: $network_name"
    
    # Check if VM already exists
    if openstack server show "$vm_name" >/dev/null 2>&1; then
        log "INFO" "Test VM '$vm_name' already exists"
        return 0
    fi
    
    # Get network ID
    local network_id=$(openstack network show "$network_name" -f value -c id 2>/dev/null)
    if [[ -z "$network_id" ]]; then
        log "ERROR" "Network '$network_name' not found"
        return 1
    fi
    
    # Get security group IDs (both custom and default)
    local custom_sg_id=$(openstack security group show "$SECURITY_GROUP_NAME" -f value -c id 2>/dev/null)
    local default_sg_id=$(openstack security group show "default" -f value -c id 2>/dev/null)
    
    # Build security group parameter
    local sg_params=""
    if [[ -n "$custom_sg_id" ]]; then
        sg_params="--security-group '$custom_sg_id'"
    fi
    if [[ -n "$default_sg_id" ]]; then
        sg_params="$sg_params --security-group '$default_sg_id'"
    fi
    
    if [[ -z "$sg_params" ]]; then
        log "WARNING" "No security groups found, proceeding without them"
    fi
    
    # Check if key exists
    local key_param=""
    if openstack keypair show "$TESTVM_KEY" >/dev/null 2>&1; then
        key_param="--key-name '$TESTVM_KEY'"
    else
        log "WARNING" "Key '$TESTVM_KEY' not found, proceeding without key"
    fi
    
    # Build server create command
    local create_cmd="openstack server create"
    create_cmd="$create_cmd --image '$image_name'"
    create_cmd="$create_cmd --flavor '$TESTVM_FLAVOR'"
    create_cmd="$create_cmd --network '$network_id'"
    create_cmd="$create_cmd --availability-zone 'nova:$hypervisor'"
    create_cmd="$create_cmd --config-drive true"
    
    # Add security groups if available
    if [[ -n "$sg_params" ]]; then
        create_cmd="$create_cmd $sg_params"
    fi
    
    # Add key if available
    if [[ -n "$key_param" ]]; then
        create_cmd="$create_cmd $key_param"
    fi
    
    create_cmd="$create_cmd '$vm_name' -f value -c id"
    
    local vm_id=$(eval "$create_cmd")
    
    if [[ -n "$vm_id" ]]; then
        log "INFO" "Successfully launched test VM: $vm_name (ID: $vm_id) on hypervisor: $hypervisor, network: $network_name"
        add_to_state "test_vms" "$vm_id" "$vm_name"
        
        # Show VM details
        openstack server show "$vm_id" -c name -c status -c networks -c flavor -c image
    else
        log "ERROR" "Failed to launch test VM: $vm_name on hypervisor: $hypervisor, network: $network_name"
        return 1
    fi
}

testvm() {
    log "INFO" "Starting test VM deployment..."
    
    check_prerequisites
    
    # Get available hypervisors
    local hypervisors=($(get_available_hypervisors))
    
    if [[ ${#hypervisors[@]} -eq 0 ]]; then
        log "ERROR" "No hypervisors found"
        return 1
    fi
    
    log "INFO" "Found ${#hypervisors[@]} hypervisors: ${hypervisors[*]}"
    log "INFO" "Will create VMs on networks: ${TESTVM_NETWORKS[*]}"
    
    # Launch test VMs on each hypervisor for each network in parallel
    local pids=()
    for hypervisor in "${hypervisors[@]}"; do
        for network in "${TESTVM_NETWORKS[@]}"; do
            launch_test_vm "$hypervisor" "$network" &
            pids+=($!)
        done
    done
    
    # Wait for all background jobs to complete
    log "INFO" "Waiting for all VM launches to complete..."
    for pid in "${pids[@]}"; do
        wait $pid
    done
    
    log "INFO" "Test VM deployment completed!"
    
    # Show summary
    echo ""
    echo "Test VM Summary:"
    echo "==============="
    openstack server list --name "${TESTVM_PREFIX}-" -c Name -c Status -c Networks -c "Host"
}

usage() {
    echo "Usage: $0 [setup|cleanup|status|testvm]"
    echo ""
    echo "Commands:"
    echo "  setup   - Download images, convert to raw format, create flavors, networks, routers, security groups, volume types, set quotas"
    echo "  cleanup - Remove all created resources including test VMs"
    echo "  status  - Show current state of created resources"
    echo "  testvm  - Launch test VMs on all available hypervisors"
    echo ""
    echo "Prerequisites:"
    echo "  - OpenStack CLI tools installed"
    echo "  - OpenStack credentials sourced (run 'source public-openrc.sh')"
    echo "  - wget and jq installed"
}

# Show status
status() {
    if [[ ! -f "$STATE_FILE" ]]; then
        echo "No state file found. Run 'setup' first."
        return 0
    fi
    
    echo "OpenStack Seeding Status:"
    echo "========================"
    
    echo "Images:"
    jq -r '.images[] | "  - \(.name) (ID: \(.id))"' "$STATE_FILE"
    
    echo "Flavors:"
    jq -r '.flavors[] | "  - \(.name) (ID: \(.id))"' "$STATE_FILE"
    
    echo "Volume Types:"
    jq -r '.volume_types[] | "  - \(.name) (ID: \(.id))"' "$STATE_FILE"
    
    echo "Networks:"
    jq -r '.networks[] | "  - \(.name) (ID: \(.id))"' "$STATE_FILE"
    
    echo "Subnets:"
    jq -r '.subnets[] | "  - \(.name) (ID: \(.id))"' "$STATE_FILE"
    
    echo "Routers:"
    jq -r '.routers[] | "  - \(.name) (ID: \(.id))"' "$STATE_FILE"
    
    echo "Security Groups:"
    jq -r '.security_groups[] | "  - \(.name) (ID: \(.id))"' "$STATE_FILE"
    
    echo "Test VMs:"
    jq -r '.test_vms[] | "  - \(.name) (ID: \(.id))"' "$STATE_FILE"
    
    echo "Quotas Updated:"
    jq -r '.quotas_updated[] | "  - \(.name) for project \(.id)"' "$STATE_FILE"
}

# Main execution
main() {
    case "${1:-}" in
        setup)
            setup
            ;;
        cleanup)
            cleanup
            ;;
        status)
            status
            ;;
        testvm)
            testvm
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

# Execute main function with all arguments
main "$@"