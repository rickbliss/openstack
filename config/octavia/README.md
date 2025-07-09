Reference: 

https://docs.openstack.org/kolla-ansible/latest/reference/networking/octavia.html
sudo apt -y install debootstrap qemu-utils git kpartx
git clone https://opendev.org/openstack/octavia -b 2025.1
python3 -m venv dib-venv
source dib-venv/bin/activate
pip install diskimage-builder

cd octavia/diskimage-create
./diskimage-create.sh

. /etc/kolla/octavia-openrc.sh < Needs done on control node since internal.openstack


openstack image create amphora-x64-haproxy.qcow2 --container-format bare --disk-format qcow2 --private --tag amphora --file amphora-x64-haproxy.qcow2 --property hw_architecture='x86_64' --property hw_rng_model=virtio

