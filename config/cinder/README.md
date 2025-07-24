# Cinder Service Configuration

## Overview
OpenStack Block Storage Service - Manages block storage volumes and snapshots
 (https://docs.openstack.org/cinder/latest/admin/multi-backend.html#volume-type)


https://docs.ceph.com/en/reef/rbd/rbd-openstack/

(cinder-volume)[cinder@bc01 /]$ cinder-manage service list
Binary           Host                                 Zone             Status     State Updated At           RPC Version  Object Version  Cluster                             
cinder-scheduler bc00                                 nova             enabled    :-)   2025-07-10 19:36:39  3.12         1.39                                                
cinder-scheduler bc02                                 nova             enabled    :-)   2025-07-10 19:36:40  3.12         1.39                                                
cinder-scheduler bc03                                 nova             enabled    :-)   2025-07-10 19:36:46  3.12         1.39                                                
cinder-volume    bc01@ssd-rbd                         nova             enabled    :-)   2025-07-10 19:36:44  3.20         1.39            cinder_ha_cluster@ssd-rbd           
cinder-volume    bc01@hdd-rbd                         nova             enabled    :-)   2025-07-10 19:36:44  3.20         1.39            cinder_ha_cluster@hdd-rbd           
cinder-volume    bc02@ssd-rbd                         nova             enabled    :-)   2025-07-10 19:36:46  3.20         1.39            cinder_ha_cluster@ssd-rbd           
cinder-volume    bc02@hdd-rbd                         nova             enabled    :-)   2025-07-10 19:36:38  3.20         1.39            cinder_ha_cluster@hdd-rbd           
cinder-volume    bc02@ceph                            nova             enabled    XXX   2025-07-10 01:14:03  3.20         1.39            cinder_ha_cluster@ceph              
cinder-backup    bc01                                 nova             enabled    :-)   2025-07-10 19:36:42  2.4          1.39                                                
cinder-backup    bc02                                 nova             enabled    :-)   2025-07-10 19:36:44  2.4          1.39                                                
cinder-volume    bc02@hdd-backup                      nova             enabled    :-)   2025-07-10 19:36:45  3.20         1.39            cinder_ha_cluster@hdd-backup        
cinder-volume    bc01@hdd-backup                      nova             enabled    :-)   2025-07-10 19:36:44  3.20         1.39            cinder_ha_cluster@hdd-backup  

(cinder-volume)[cinder@bc01 /]$ cinder-manage service list
Binary           Host                                 Zone             Status     State Updated At           RPC Version  Object Version  Cluster                             
cinder-scheduler bc00                                 nova             enabled    :-)   2025-07-10 19:40:49  3.12         1.39                                                
cinder-scheduler bc02                                 nova             enabled    :-)   2025-07-10 19:40:50  3.12         1.39                                                
cinder-scheduler bc03                                 nova             enabled    :-)   2025-07-10 19:40:46  3.12         1.39                                                
cinder-volume    bc01@ssd-rbd                         nova             enabled    :-)   2025-07-10 19:40:45  3.20         1.39            cinder_ha_cluster@ssd-rbd           
cinder-volume    bc01@hdd-rbd                         nova             enabled    :-)   2025-07-10 19:40:44  3.20         1.39            cinder_ha_cluster@hdd-rbd           
cinder-volume    bc02@ssd-rbd                         nova             enabled    :-)   2025-07-10 19:40:46  3.20         1.39            cinder_ha_cluster@ssd-rbd           
cinder-volume    bc02@hdd-rbd                         nova             enabled    :-)   2025-07-10 19:40:48  3.20         1.39            cinder_ha_cluster@hdd-rbd           
cinder-backup    bc01                                 nova             enabled    :-)   2025-07-10 19:40:42  2.4          1.39                                                
cinder-backup    bc02                                 nova             enabled    :-)   2025-07-10 19:40:44  2.4          1.39                                                
cinder-volume    bc02@hdd-backup                      nova             enabled    :-)   2025-07-10 19:40:45  3.20         1.39            cinder_ha_cluster@hdd-backup        
cinder-volume    bc01@hdd-backup                      nova             enabled    :-)   2025-07-10 19:40:44  3.20         1.39            cinder_ha_cluster@hdd-backup  

You can create a volume from an image using the Cinder command line tool:

cinder create --image-id {id of image} --display-name {name of volume} {size of volume}

You can use qemu-img to convert from one format to another. For example:

qemu-img convert -f {source-format} -O {output-format} {source-filename} {output-filename}
qemu-img convert -f qcow2 -O raw precise-cloudimg.img precise-cloudimg.raw

When Glance and Cinder are both using Ceph block devices, the image is a copy-on-write clone, so new volumes are created quickly. In the OpenStack dashboard, you can boot from that volume by performing the following steps:



openstack volume type set __DEFAULT__ --property volume_backend_name=ssd-rbd


## Directory Structure
This directory contains configuration files for the cinder service deployed via Kolla-Ansible.

## Configuration Files

- **.gitkeep**: Configuration file
- **README.md**: Configuration file
- **cinder.conf**: Configuration file

## Subdirectories

- **cinder-backup/**: Service-specific configuration directory
- **cinder-volume/**: Service-specific configuration directory

## Usage Notes

- These configuration files are managed by Kolla-Ansible
- Do not modify these files directly unless you understand the implications
- Back up configurations before making changes
- Restart the cinder service after configuration changes

## Related Documentation


- [Kolla-Ansible Cinder Configuration](https://docs.openstack.org/kolla-ansible/latest/reference/)
- [OpenStack Cinder Documentation](https://docs.openstack.org/cinder/latest/)

## Troubleshooting

Check service logs for configuration-related issues:
```bash
# View service logs
sudo docker logs kolla_cinder_1

# Check service status
sudo docker ps | grep cinder
```

---
*Generated by Kolla Config README Generator*  
*Last updated: Wed 09 Jul 2025 01:17:17 PM EDT*
