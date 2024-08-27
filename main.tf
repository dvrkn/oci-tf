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

resource "oci_core_vcn" "atlas_vcn" {
  cidr_block     = "10.1.0.0/16"
  is_ipv6enabled = true
  compartment_id = var.compartment_ocid
  display_name = format("%sVCN", replace(title(var.instance_name), "/\\s/", ""))
  dns_label = format("%svcn", lower(replace(var.instance_name, "/\\s/", "")))
}

data "oci_identity_availability_domain" "ad" {
  compartment_id = var.tenancy_ocid
  ad_number      = var.availability_domain
}

resource "oci_core_security_list" "atlas_security_list" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.atlas_vcn.id
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

  #   # Allow inbound traffic on all ports for all protocols
  #   ingress_security_rules {
  #     protocol  = "all"
  #     source    = "0.0.0.0/0"
  #     stateless = false
  #   }
  #
  #   ingress_security_rules {
  #     protocol  = "all"
  #     source    = "::/0"
  #     stateless = false
  #   }

  # Allow inbound icmp traffic of a specific type
  ingress_security_rules {
    protocol  = 1
    source    = "0.0.0.0/0"
    stateless = false

    icmp_options {
      type = 3
      code = 4
    }
  }
}

resource "oci_core_subnet" "atlas_subnet" {
  availability_domain = data.oci_identity_availability_domain.ad.name
  cidr_block          = "10.1.20.0/24"
  display_name = format("%sSubnet", replace(title(var.instance_name), "/\\s/", ""))
  dns_label = format("%ssubnet", lower(replace(var.instance_name, "/\\s/", "")))
  security_list_ids = [oci_core_security_list.atlas_security_list.id]
  compartment_id      = var.compartment_ocid
  vcn_id              = oci_core_vcn.atlas_vcn.id
  route_table_id      = oci_core_vcn.atlas_vcn.default_route_table_id
  dhcp_options_id     = oci_core_vcn.atlas_vcn.default_dhcp_options_id

  ipv6cidr_blocks = cidrsubnets(oci_core_vcn.atlas_vcn.ipv6cidr_blocks[0], 8)
}

resource "oci_core_internet_gateway" "atlas_internet_gateway" {
  compartment_id = var.compartment_ocid
  display_name = format("%sIGW", replace(title(var.instance_name), "/\\s/", ""))
  vcn_id         = oci_core_vcn.atlas_vcn.id
}

resource "oci_core_default_route_table" "default_route_table" {
  manage_default_resource_id = oci_core_vcn.atlas_vcn.default_route_table_id
  display_name               = "DefaultRouteTable"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.atlas_internet_gateway.id
  }

  route_rules {
    destination       = "::/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.atlas_internet_gateway.id
  }
}


resource "oci_core_instance" "atlas_instance" {
  availability_domain = data.oci_identity_availability_domain.ad.name
  compartment_id      = var.compartment_ocid
  display_name = format("%s", replace(title(var.instance_name), "/\\s/", ""))
  shape               = var.instance_shape

  shape_config {
    ocpus         = var.instance_ocpus
    memory_in_gbs = var.instance_shape_config_memory_in_gbs
  }

  create_vnic_details {
    subnet_id                 = oci_core_subnet.atlas_subnet.id
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
  value = [oci_core_instance.atlas_instance.*.public_ip]
}
