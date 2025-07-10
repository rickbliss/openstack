#!/bin/bash

# Kolla Config README Generator
# This script creates boilerplate README.md files for each service directory under /etc/kolla/config

CONFIG_BASE="/etc/kolla/config"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to get service description
get_service_description() {
    local service=$1
    case $service in
        "cinder")
            echo "OpenStack Block Storage Service - Manages block storage volumes and snapshots"
            ;;
        "glance")
            echo "OpenStack Image Service - Manages virtual machine images"
            ;;
        "neutron")
            echo "OpenStack Networking Service - Provides networking capabilities"
            ;;
        "nova")
            echo "OpenStack Compute Service - Manages virtual machines and compute resources"
            ;;
        "octavia")
            echo "OpenStack Load Balancer Service - Provides load balancing as a service"
            ;;
        "horizon")
            echo "OpenStack Dashboard - Web-based user interface for OpenStack services"
            ;;
        "hacluster-corosync")
            echo "High Availability Cluster - Corosync messaging layer configuration"
            ;;
        "hacluster-pacemaker")
            echo "High Availability Cluster - Pacemaker resource manager configuration"
            ;;
        *)
            echo "OpenStack service configuration"
            ;;
    esac
}

# Function to analyze directory contents
analyze_directory() {
    local dir=$1
    local files=()
    local subdirs=()
    
    if [[ -d "$dir" ]]; then
        while IFS= read -r -d '' file; do
            if [[ -f "$file" ]]; then
                files+=("$(basename "$file")")
            elif [[ -d "$file" ]]; then
                subdirs+=("$(basename "$file")")
            fi
        done < <(find "$dir" -maxdepth 1 -mindepth 1 -print0)
    fi
    
    echo "FILES:(${files[*]}) SUBDIRS:(${subdirs[*]})"
}

# Function to get file purpose
get_file_purpose() {
    local file=$1
    case $file in
        "*.conf")
            echo "Main configuration file"
            ;;
        "*.ini")
            echo "Configuration file"
            ;;
        "*.keyring")
            echo "Ceph authentication keyring"
            ;;
        "ceph.conf")
            echo "Ceph cluster configuration"
            ;;
        "*.pem")
            echo "SSL/TLS certificate or key file"
            ;;
        "*.crt")
            echo "SSL/TLS certificate file"
            ;;
        "*.key")
            echo "SSL/TLS private key file"
            ;;
        "authkey")
            echo "Cluster authentication key"
            ;;
        "ml2_conf.ini")
            echo "Neutron ML2 plugin configuration"
            ;;
        "neutron_vpnaas.conf")
            echo "Neutron VPN-as-a-Service configuration"
            ;;
        *)
            echo "Configuration file"
            ;;
    esac
}

# Function to generate README content
generate_readme() {
    local service=$1
    local service_dir=$2
    local description=$(get_service_description "$service")
    local analysis=$(analyze_directory "$service_dir")
    
    # Extract files and subdirs from analysis
    local files_part=$(echo "$analysis" | sed 's/.*FILES:(\([^)]*\)).*/\1/')
    local subdirs_part=$(echo "$analysis" | sed 's/.*SUBDIRS:(\([^)]*\)).*/\1/')
    
    # Convert to arrays
    IFS=' ' read -ra files_array <<< "$files_part"
    IFS=' ' read -ra subdirs_array <<< "$subdirs_part"
    
    cat << EOF
# ${service^} Service Configuration

## Overview
${description}

## Directory Structure
This directory contains configuration files for the ${service} service deployed via Kolla-Ansible.

EOF

    # Add files section if files exist
    if [[ ${#files_array[@]} -gt 0 && "${files_array[0]}" != "" ]]; then
        cat << EOF
## Configuration Files

EOF
        for file in "${files_array[@]}"; do
            if [[ -n "$file" ]]; then
                local purpose=$(get_file_purpose "$file")
                echo "- **${file}**: ${purpose}"
            fi
        done
        echo
    fi
    
    # Add subdirectories section if subdirs exist
    if [[ ${#subdirs_array[@]} -gt 0 && "${subdirs_array[0]}" != "" ]]; then
        cat << EOF
## Subdirectories

EOF
        for subdir in "${subdirs_array[@]}"; do
            if [[ -n "$subdir" ]]; then
                echo "- **${subdir}/**: Service-specific configuration directory"
            fi
        done
        echo
    fi
    
    cat << EOF
## Usage Notes

- These configuration files are managed by Kolla-Ansible
- Do not modify these files directly unless you understand the implications
- Back up configurations before making changes
- Restart the ${service} service after configuration changes

## Related Documentation

- [Kolla-Ansible ${service^} Configuration](https://docs.openstack.org/kolla-ansible/latest/reference/)
- [OpenStack ${service^} Documentation](https://docs.openstack.org/${service}/latest/)

## Troubleshooting

Check service logs for configuration-related issues:
\`\`\`bash
# View service logs
sudo docker logs kolla_${service}_1

# Check service status
sudo docker ps | grep ${service}
\`\`\`

---
*Generated by Kolla Config README Generator*  
*Last updated: $(date)*
EOF
}

# Main execution
main() {
    print_status "Starting Kolla Config README Generator"
    
    # Check if config directory exists
    if [[ ! -d "$CONFIG_BASE" ]]; then
        print_error "Config directory not found: $CONFIG_BASE"
        exit 1
    fi
    
    # Change to config directory
    cd "$CONFIG_BASE" || exit 1
    
    # Counter for created files
    local created_count=0
    local skipped_count=0
    
    # Process each service directory
    for service_dir in */; do
        if [[ -d "$service_dir" ]]; then
            service=$(basename "$service_dir")
            readme_path="${service_dir}README.md"
            
            print_status "Processing service: $service"
            
            # Check if README already exists
            if [[ -f "$readme_path" ]]; then
                print_warning "README.md already exists in $service_dir - skipping"
                ((skipped_count++))
                continue
            fi
            
            # Generate README content
            generate_readme "$service" "$service_dir" > "$readme_path"
            
            if [[ $? -eq 0 ]]; then
                print_status "Created README.md for $service"
                ((created_count++))
            else
                print_error "Failed to create README.md for $service"
            fi
        fi
    done
    
    # Summary
    echo
    print_status "README Generation Complete!"
    print_status "Created: $created_count files"
    print_status "Skipped: $skipped_count files (already existed)"
    
    # List created files
    if [[ $created_count -gt 0 ]]; then
        echo
        print_status "Created README files:"
        find "$CONFIG_BASE" -name "README.md" -newer "$0" 2>/dev/null | while read -r file; do
            echo "  - $file"
        done
    fi
}

# Run main function
main "$@"