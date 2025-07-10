# OpenStack Octavia Amphora Image Creation

## Reference
[Kolla-Ansible Octavia Networking Documentation](https://docs.openstack.org/kolla-ansible/latest/reference/networking/octavia.html)

## Prerequisites

Install required packages:
```bash
sudo apt -y install debootstrap qemu-utils git kpartx
```

## Build Process

### 1. Clone Octavia Repository
```bash
git clone https://opendev.org/openstack/octavia -b 2025.1
```

### 2. Set Up Virtual Environment
```bash
python3 -m venv dib-venv
source dib-venv/bin/activate
pip install diskimage-builder
```

### 3. Create Amphora Image
```bash
cd octavia/diskimage-create
./diskimage-create.sh
```

### 4. Upload Image to OpenStack
**Note:** This step needs to be done on the control node since it requires access to `internal.openstack`

```bash
# Source the OpenStack credentials
. /etc/kolla/octavia-openrc.sh

# Create the amphora image in OpenStack
openstack image create amphora-x64-haproxy.qcow2 \
  --container-format bare \
  --disk-format qcow2 \
  --private \
  --tag amphora \
  --file amphora-x64-haproxy.qcow2 \
  --property hw_architecture='x86_64' \
  --property hw_rng_model=virtio
```

## Important Notes

- The image upload command must be executed on the control node
- Ensure you have proper OpenStack credentials configured
- The amphora image will be tagged and configured with specific hardware properties for optimal performance

