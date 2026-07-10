provider "oci" {
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
  region           = var.region
}

terraform {
  required_providers {
    oci = {
      source = "oracle/oci"
    }
  }
}

resource "oci_core_vcn" "main" {
  cidr_block     = "10.1.0.0/16"
  is_ipv6enabled = true
  compartment_id = var.compartment_ocid
  display_name = format("%sVCN", replace(title(var.instance_name), "/\\s/", ""))
  dns_label = format("%svcn", lower(replace(var.instance_name, "/\\s/", "")))
}

data "oci_identity_availability_domain" "main" {
  compartment_id = var.tenancy_ocid
  ad_number      = var.availability_domain
}

data "http" "my_ip" {
  url = "https://ipv4.icanhazip.com/"
}

locals {
  cloudflare_ip_ranges = [
    "173.245.48.0/20",
    "103.21.244.0/22",
    "103.22.200.0/22",
    "103.31.4.0/22",
    "141.101.64.0/18",
    "108.162.192.0/18",
    "190.93.240.0/20",
    "188.114.96.0/20",
    "197.234.240.0/22",
    "198.41.128.0/17",
    "162.158.0.0/15",
    "104.16.0.0/13",
    "104.24.0.0/14",
    "172.64.0.0/13",
    "131.0.72.0/22",
    "2400:cb00::/32",
    "2606:4700::/32",
    "2803:f800::/32",
    "2405:b500::/32",
    "2405:8100::/32",
    "2a06:98c0::/29",
    "2c0f:f248::/32",
  ]
}

resource "oci_core_security_list" "main" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name = format("%sSecurityList", replace(title(var.instance_name), "/\\s/", ""))

  # Allow outbound traffic on all ports for all protocols
  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
    stateless   = false
  }

  egress_security_rules {
    destination = "::/0"
    protocol    = "all"
    stateless   = false
  }

  ingress_security_rules {
    protocol  = "6"
    source    = "${chomp(data.http.my_ip.response_body)}/32"
    stateless = false

    # tcp_options {
    #   min = 22
    #   max = 22
    # }
  }
}

resource "oci_core_security_list" "cloudflare" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name = format("%sCloudflareSecurityList", replace(title(var.instance_name), "/\\s/", ""))

  dynamic "ingress_security_rules" {
    for_each = toset(local.cloudflare_ip_ranges)
    content {
      protocol  = "6"
      source    = ingress_security_rules.value
      stateless = false

      tcp_options {
        min = 80
        max = 80
      }
    }
  }
}

resource "oci_core_subnet" "main" {
  availability_domain = data.oci_identity_availability_domain.main.name
  cidr_block          = "10.1.20.0/24"
  display_name = format("%sSubnet", replace(title(var.instance_name), "/\\s/", ""))
  dns_label = format("%ssubnet", lower(replace(var.instance_name, "/\\s/", "")))
  security_list_ids = [oci_core_security_list.main.id, oci_core_security_list.cloudflare.id]
  compartment_id      = var.compartment_ocid
  vcn_id              = oci_core_vcn.main.id
  route_table_id      = oci_core_vcn.main.default_route_table_id
  dhcp_options_id     = oci_core_vcn.main.default_dhcp_options_id

  ipv6cidr_blocks = cidrsubnets(oci_core_vcn.main.ipv6cidr_blocks[0], 8)
}

resource "oci_core_internet_gateway" "main" {
  compartment_id = var.compartment_ocid
  display_name = format("%sIGW", replace(title(var.instance_name), "/\\s/", ""))
  vcn_id         = oci_core_vcn.main.id
}

resource "oci_core_default_route_table" "main" {
  manage_default_resource_id = oci_core_vcn.main.default_route_table_id
  display_name               = "DefaultRouteTable"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.main.id
  }

  route_rules {
    destination       = "::/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.main.id
  }
}


resource "oci_core_instance" "main" {
  availability_domain = data.oci_identity_availability_domain.main.name
  compartment_id      = var.compartment_ocid
  display_name = format("%s", replace(title(var.instance_name), "/\\s/", ""))
  shape               = var.instance_shape

  shape_config {
    ocpus         = var.instance_ocpus
    memory_in_gbs = var.instance_shape_config_memory_in_gbs
  }

  create_vnic_details {
    subnet_id                 = oci_core_subnet.main.id
    assign_ipv6ip             = true
    display_name = format("%sVNIC", replace(title(var.instance_name), "/\\s/", ""))
    assign_public_ip          = true
    assign_private_dns_record = true
    hostname_label = format("%s", lower(replace(var.instance_name, "/\\s/", "")))
  }

  source_details {
    source_type             = var.instance_source_type
    source_id               = var.instance_image_ocid
    boot_volume_size_in_gbs = var.boot_volume_size_in_gbs
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_keys
  }

  timeouts {
    create = "60m"
  }
}

output "instance_public_ips" {
  value = [oci_core_instance.main.*.public_ip]
}
