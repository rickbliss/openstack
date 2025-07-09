# Bliss Kolla-Ansible OpenStack Deployment

## Overview
This directory contains the configuration and operational files for an OpenStack deployment managed by Kolla-Ansible. This deployment provides a complete cloud infrastructure platform with compute, storage, networking, and additional services.


### Core Services
- **[Nova](config/nova/README.md)** - Compute service managing virtual machines
- **[Neutron](config/neutron/README.md)** - Networking service providing network connectivity
- **[Cinder](config/cinder/README.md)** - Block storage service for persistent volumes
- **[Glance](config/glance/README.md)** - Image service managing VM images

### Additional Services
- **[Octavia](config/octavia/README.md)** - Load balancer as a service
- **[Horizon](config/horizon/README.md)** - Web dashboard interface

### High Availability (BROKEN RIGHT NOW)
- **[HACluster Corosync](config/hacluster-corosync/README.md)** - Cluster messaging layer
- **[HACluster Pacemaker](config/hacluster-pacemaker/README.md)** - Resource management


## Storage Backend

This deployment uses **Ceph** as the storage backend for:
- **Cinder**: Block storage volumes
- **Glance**: Image storage
- **Nova**: Ephemeral storage (optional)

Ceph configuration and keyrings are distributed across service directories.

## Network Configuration

### Network Types
- **Internal Network**: Private network for service communication
- **External Network**: Public-facing network for user access
- **Management Network**: Administrative network for deployment

### Load Balancing
Octavia provides load balancing services with:
- SSL certificate management
- Health monitoring
- Auto-scaling capabilities

## Deployment Management

### Kolla-Ansible Commands
```bash
# Deploy services
kolla-ansible -i multinode deploy -v

# Reconfigure services
kolla-ansible -i multinode reconfigure

# Upgrade deployment
kolla-ansible -i multinode upgrade

# Post-deployment setup
kolla-ansible -i multinode post-deploy
```
# Destroy services
kolla-ansible -i multinode destroy --include-images --include-dev -v

### Configuration Updates
1. Modify `globals.yml` for global changes
2. Update service-specific configs in `config/` directories
3. Run reconfigure: `kolla-ansible -i multinode reconfigure`

## Monitoring and Troubleshooting

### Service Status
```bash
# Check all containers
podman ps

# Check specific service
podman ps | grep <service-name>

# View service logs
podman logs <container-name>
```

### Common Issues
- **Certificate Expiry**: Check certificate validity dates
- **Service Communication**: Verify network connectivity
- **Storage Issues**: Check Ceph cluster health
- **Authentication**: Verify keystone services

### Log Locations
- **Deployment Logs**: `/etc/kolla/ansible.log`
- **Service Logs**: `podman logs <container>`
- **Host Logs**: `/var/log/kolla/`

## Security Considerations

### Access Control
- Admin credentials provide full system access
- Public credentials are for end-user operations
- Service-specific credentials (like Octavia) have limited scope

### Certificate Security
- Private keys are stored in restricted directories
- Certificates should be regularly renewed
- Use strong passphrases for private keys

### Network Security
- Internal traffic is encrypted
- External access requires proper authentication
- Firewall rules should be configured appropriately

## Backup and Recovery

### Critical Files to Backup
```bash
# Configuration files
/etc/kolla/globals.yml
/etc/kolla/passwords.yml
/etc/kolla/config/

# Certificates
/etc/kolla/certificates/

# Inventory
/etc/kolla/multinode
```

### Database Backup
```bash
# Backup all databases
kolla-ansible -i multinode mariadb_backup

# Restore from backup
kolla-ansible -i multinode mariadb_recovery
```

## Maintenance

### Regular Tasks
- [ ] Monitor certificate expiration dates
- [ ] Update system packages
- [ ] Check storage capacity
- [ ] Review security logs
- [ ] Backup configurations

### Scheduled Maintenance
- **Monthly**: Review and update configurations
- **Quarterly**: Security audit and certificate renewal
- **Annually**: Major version upgrades

## Documentation Links


### Community Resources
- [OpenStack Mailing Lists](https://lists.openstack.org/)
- [Kolla IRC Channel](https://webchat.oftc.net/?channels=openstack-kolla)
- [OpenStack Forums](https://ask.openstack.org/)

### Emergency Contacts
- **System Administrator**: [Your contact information]
- **OpenStack Team**: [Team contact information]
- **On-Call Support**: [Emergency contact information]

---

**Deployment Information**
- **Environment**: Production/Staging/Development
- **OpenStack Version**: 2025.1 (Epoxy Slurp)
- **Kolla-Ansible Version**: Latest
- **Deployment Date**: [Date of deployment]
- **Last Updated**: [Last configuration update]

**Important Notes**
- Always backup configurations before making changes
- Test changes in a development environment first
- Follow change management procedures for production updates
- Monitor service health after any configuration changes