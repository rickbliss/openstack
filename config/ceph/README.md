# Ceph OpenStack Integration Guide

## Overview
This guide provides step-by-step instructions for setting up Ceph storage backend integration with OpenStack using Kolla-Ansible deployment. The setup includes creating storage pools for different performance tiers (SSD/HDD) and configuring OpenStack services to use Ceph for persistent storage.

## Prerequisites

### System Requirements
- Ceph cluster (version 18.2.7 or later)
- OpenStack deployment via Kolla-Ansible
- SSH access to all cluster nodes
- Root/sudo privileges

### Host Configuration
**Control Nodes**: bc00, bc01, bc02, bc03, bc04

## Installation Steps

### 1. Install Ceph Administration Tools

```bash
# Set Ceph release version
CEPH_RELEASE=18.2.7

# Download cephadm
curl --silent --remote-name --location https://download.ceph.com/rpm-${CEPH_RELEASE}/el9/noarch/cephadm

# Add Ceph repository (Noble doesn't have release, use Jammy)
sudo apt-add-repository 'deb https://download.ceph.com/debian-reef/ jammy main'
```

### 2. Archive Existing Crash Reports

```bash
# Clear any existing crash reports
sudo ceph crash archive-all
```

## Storage Pool Configuration

### Performance-Tiered Storage Strategy
This setup uses SSD storage for OS/boot volumes and HDD storage for data volumes to optimize performance and cost.

### Create Storage Pools

```bash
# SSD Pools (High Performance)
sudo ceph osd pool create ssd-vms 32 32 replicated ssd_rule
sudo ceph osd pool set ssd-vms size 2
sudo ceph osd pool set ssd-vms min_size 2

sudo ceph osd pool create ssd-volumes 32 32 replicated ssd_rule
sudo ceph osd pool set ssd-volumes size 2
sudo ceph osd pool set ssd-volumes min_size 2

sudo ceph osd pool create images 32 32 replicated ssd_rule
sudo ceph osd pool set images size 2
sudo ceph osd pool set images min_size 2

# HDD Pools (Cost-Effective Storage)
sudo ceph osd pool create hdd-vms 128 128 replicated hdd_rule
sudo ceph osd pool set hdd-vms size 3
sudo ceph osd pool set hdd-vms min_size 2

sudo ceph osd pool create hdd-volumes 128 128 replicated hdd_rule
sudo ceph osd pool set hdd-volumes size 3
sudo ceph osd pool set hdd-volumes min_size 2

sudo ceph osd pool create backups 128 128 replicated hdd_rule
sudo ceph osd pool set backups size 3
sudo ceph osd pool set backups min_size 2
```

### Enable RBD Application on Pools

```bash
ceph osd pool application enable ssd-vms rbd
ceph osd pool application enable ssd-volumes rbd
ceph osd pool application enable hdd-vms rbd
ceph osd pool application enable hdd-volumes rbd
ceph osd pool application enable backups rbd
ceph osd pool application enable images rbd
```

## OpenStack Service Authentication

### Configure Client Capabilities

Create and run the following script to set up proper authentication:

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "🔹 Setting caps for client.glance..."
ceph auth caps client.glance \
  mon 'profile rbd' \
  osd 'profile rbd pool=images' \
  mgr 'profile rbd pool=images'

echo "🔹 Setting caps for client.cinder..." 
ceph auth caps client.cinder \
  mon 'profile rbd' \
  osd 'profile rbd pool=ssd-volumes, profile rbd pool=hdd-volumes, profile rbd pool=ssd-vms, profile rbd pool=hdd-vms, profile rbd-read-only pool=images' \
  mgr 'profile rbd pool=ssd-volumes, profile rbd pool=hdd-volumes, profile rbd pool=hdd-vms, profile rbd pool=ssd-vms'

echo "🔹 Setting caps for client.nova..."
ceph auth caps client.nova \
  mon 'profile rbd' \
  osd 'allow class-read object_prefix rbd_children, profile rbd pool=images, profile rbd pool=hdd-volumes, profile rbd pool=ssd-volumes, profile rbd pool=ssd-vms, profile rbd pool=hdd-vms' \
  mgr 'profile rbd-read-only pool=images, profile rbd pool=hdd-volumes, profile rbd pool=ssd-volumes, profile rbd pool=ssd-vms, profile rbd pool=hdd-vms'

echo "🔹 Setting caps for client.cinder-backup..."
ceph auth caps client.cinder-backup \
  mon 'allow r' \
  osd 'allow class-read object_prefix rbd_children, allow rwx pool=backups, allow rwx pool=hdd-volumes, allow rwx pool=ssd-volumes'

echo "✅ All caps applied."
```

### Export Authentication Keyrings

```bash
echo "🔹 Exporting keyring for client.glance..."
ceph auth get client.glance -o /etc/ceph/ceph.client.glance.keyring

echo "🔹 Exporting keyring for client.cinder..."
ceph auth get client.cinder -o /etc/ceph/ceph.client.cinder.keyring

echo "🔹 Exporting keyring for client.nova..."
ceph auth get client.nova -o /etc/ceph/ceph.client.nova.keyring

echo "🔹 Exporting keyring for client.cinder-backup..."
ceph auth get client.cinder-backup -o /etc/ceph/ceph.client.cinder-backup.keyring

echo "✅ All keyrings exported successfully."
```

## Cluster-Wide Configuration Distribution

### Distribute Keyrings to All Nodes

```bash
# Distribute keyrings to all cluster nodes
for host in localhost bc00 bc01 bc02 bc03 bc04; do
  sudo ceph auth get-or-create client.glance | ssh "$host" sudo tee /etc/ceph/ceph.client.glance.keyring
  sudo ceph auth get-or-create client.cinder | ssh "$host" sudo tee /etc/ceph/ceph.client.cinder.keyring
  sudo ceph auth get-or-create client.nova | ssh "$host" sudo tee /etc/ceph/ceph.client.nova.keyring
  sudo ceph auth get-or-create client.cinder-backup | ssh "$host" sudo tee /etc/ceph/ceph.client.cinder-backup.keyring
  sudo scp -i ~/.ssh/id_rsa /etc/ceph/ceph.conf $host:/etc/ceph
done
```

### Copy Keyrings to Kolla Configuration

```bash
# Copy keyrings to Kolla service directories
cp /etc/ceph/ceph.client.glance.keyring /etc/kolla/config/glance/
cp /etc/ceph/ceph.client.cinder.keyring /etc/kolla/config/cinder/
cp /etc/ceph/ceph.client.cinder.keyring /etc/kolla/config/cinder-backup/
cp /etc/ceph/ceph.client.cinder.keyring /etc/kolla/config/cinder-volume/
```

## Ceph Configuration File

### Create Optimized ceph.conf

```bash
sudo tee ceph.conf <<EOF
[client]
rbd cache = true
rbd cache writethrough until flush = true

[global]
fsid = 4c1c61ae-397e-11f0-b26f-0cc47a7cbc82
mon_host = [v2:10.0.51.40:3300/0,v1:10.0.51.40:6789/0] [v2:10.0.51.34:3300/0,v1:10.0.51.34:6789/0] [v2:10.0.51.37:3300/0,v1:10.0.51.37:6789/0] [v2:10.0.51.38:3300/0,v1:10.0.51.38:6789/0]
  
auth_cluster_required = cephx
auth_service_required = cephx
auth_client_required = cephx

[client.glance]
rbd default data pool = images
keyring = /etc/ceph/ceph.client.glance.keyring

[client.cinder]
rbd default data pool = hdd-volumes
keyring = /etc/ceph/ceph.client.cinder.keyring

[client.cinder-backup]
rbd default data pool = backups
keyring = /etc/ceph/ceph.client.cinder-backup.keyring

[client.nova]
rbd default data pool = ssd-vms
keyring = /etc/ceph/ceph.client.nova.keyring
EOF
```

### Distribute Configuration to All Nodes

```bash
for host in bc00 bc01 bc02 bc03 bc04; do
  echo "Copying ceph.conf to $host..."
  ssh $host 'mkdir -p /tmp/ceph/'
  scp ceph.conf "$host:/tmp/ceph/"
  ssh "$host" "sudo mv /tmp/ceph/* /etc/ceph/ && sudo chown root:root /etc/ceph/*"
done
```

## Storage Pool Usage Guide

### Pool Allocation Strategy

| Pool Name | Storage Type | Use Case | Performance |
|-----------|--------------|----------|-------------|
| **ssd-vms** | SSD | VM boot/OS disks | High |
| **ssd-volumes** | SSD | High-performance volumes | High |
| **hdd-vms** | HDD | Cost-effective VM storage | Standard |
| **hdd-volumes** | HDD | Bulk data storage | Standard |
| **images** | SSD | Glance images | High |
| **backups** | HDD | Volume backups | Standard |

### Performance Considerations

- **SSD Pools**: Used for OS disks and high-IOPS workloads due to random I/O and boot storms
- **HDD Pools**: Cost-effective storage for bulk data and archival purposes
- **Replication**: All pools use 3-way replication with minimum 2 replicas

## Verification Commands

### Check Pool Status
```bash
# List all pools
ceph osd pool ls

# Check pool usage
ceph df

# Verify crush rules
ceph osd crush rule ls
ceph osd crush rule dump ssd_rule
ceph osd crush rule dump hdd_rule
```

### Verify Authentication
```bash
# Test client authentication
ceph auth list | grep client.glance
ceph auth list | grep client.cinder
ceph auth list | grep client.nova
ceph auth list | grep client.cinder-backup
```

### Check OpenStack Integration
```bash
# Source OpenStack credentials
source /etc/kolla/admin-openrc.sh

# Test volume creation
openstack volume create --size 1 test-volume

# Check volume backends
openstack volume service list
```

## Troubleshooting

### Common Issues

- **Authentication Failures**: Verify keyrings are properly distributed
- **Pool Access Errors**: Check client capabilities and pool permissions
- **Performance Issues**: Monitor Ceph cluster health and OSD performance
- **Network Connectivity**: Ensure all nodes can reach Ceph monitors

### Useful Commands

```bash
# Check Ceph cluster health
ceph health detail

# Monitor Ceph operations
ceph -w

# Check OSD status
ceph osd status

# Verify RBD pools
rbd ls images
rbd ls ssd-volumes
```

## References

- [Ceph RBD OpenStack Documentation](https://docs.ceph.com/en/reef/rbd/rbd-openstack/)
- [Ceph OpenStack Cluster Deployment](https://febryandana.xyz/posts/deploy-ceph-openstack-cluster/)
- [Kolla-Ansible Ceph Integration](https://docs.openstack.org/kolla-ansible/latest/reference/storage/ceph-guide.html)

---

**Configuration Notes**
- This setup optimizes for performance by using SSD storage for OS and high-IOPS workloads
- HDD storage provides cost-effective bulk storage
- All pools use 3-way replication for data protection
- RBD caching is enabled for improved performance