terraform {
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "3.2.0"
    }
  }
}

provider "openstack" {
  # No auth_url, user_name, password, etc.
  # Terraform will use OS_AUTH_URL, OS_USERNAME, OS_PROJECT_NAME, OS_PASSWORD, OS_REGION_NAME, etc.
}
#––– Data sources –––

data "openstack_images_image_v2" "centos10" {
  name = "CentOS-10"
}

data "openstack_compute_flavor_v2" "small" {
  name = "m1.small"
}

data "openstack_networking_network_v2" "providerlan" {
  name = "ProviderLAN"
}

data "openstack_networking_subnet_v2" "providerlan_subnet" {
  name = "ProviderLAN-subnet"
}

data "openstack_networking_network_v2" "admin-genpop" {
  name = "Admin-GenPop"
}

data "openstack_networking_subnet_v2" "admin-genpop-subnet" {
  name = "Admin-GenPop-subnet"
}


data "openstack_compute_keypair_v2" "admin" {
  name = "admin"
}

data "openstack_networking_secgroup_v2" "common" {
  name = "common-client-access"
}

#––– Security group for web –––


resource "openstack_networking_secgroup_v2" "web" {
  name               = "web"
  description        = "Allow HTTP/HTTPS"
  delete_default_rules = false
}

resource "openstack_networking_secgroup_rule_v2" "web_http" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 80
  port_range_max    = 80
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.web.id
}

resource "openstack_networking_secgroup_rule_v2" "web_https" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 443
  port_range_max    = 443
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.web.id
}

#––– Create a port per VM –––

resource "openstack_networking_port_v2" "web_ports" {
  count      = 3
  name       = "apache-port-${count.index + 1}"
  network_id = data.openstack_networking_network_v2.admin-genpop.id

  security_group_ids = [
    data.openstack_networking_secgroup_v2.common.id,
    openstack_networking_secgroup_v2.web.id,
  ]
}

#––– Compute instances –––

resource "openstack_compute_instance_v2" "web" {
  count     = 3
  name      = "apache-${count.index + 1}"
  flavor_id = data.openstack_compute_flavor_v2.small.id
  image_id  = data.openstack_images_image_v2.centos10.id
  key_pair  = data.openstack_compute_keypair_v2.admin.name

  network {
    port = openstack_networking_port_v2.web_ports[count.index].id
  }

user_data = <<-EOF
  #cloud-config
  package_update: true
  packages:
    - httpd
  runcmd:
    - systemctl enable httpd
    - systemctl start httpd
    - echo "<html><body><h1>$(hostname)</h1></body></html>" > /var/www/html/index.html
EOF
}

#––– Load Balancer (Octavia) –––

resource "openstack_lb_loadbalancer_v2" "lb" {
  name          = "apache-lb"
  vip_subnet_id = data.openstack_networking_subnet_v2.providerlan_subnet.id
}

resource "openstack_lb_listener_v2" "http" {
  name            = "http-listener"
  loadbalancer_id = openstack_lb_loadbalancer_v2.lb.id
  protocol        = "HTTP"
  protocol_port   = 80
}


resource "openstack_lb_pool_v2" "web_pool" {
  name        = "web-pool"
  protocol    = "HTTP"
  listener_id = openstack_lb_listener_v2.http.id
  lb_method   = "ROUND_ROBIN"
}

resource "openstack_lb_monitor_v2" "hc" {
  pool_id     = openstack_lb_pool_v2.web_pool.id
  type        = "HTTP"
  delay       = 5
  timeout     = 3
  max_retries = 3

  http_method = "GET"
  url_path    = "/"
}

resource "openstack_lb_member_v2" "members" {
  count         = 3
  pool_id       = openstack_lb_pool_v2.web_pool.id

  address       = openstack_networking_port_v2.web_ports[count.index].all_fixed_ips[0]
  protocol_port = 80
  subnet_id     = data.openstack_networking_subnet_v2.admin-genpop-subnet.id
}
