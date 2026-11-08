# Network configuration, adopted from the NAS via an import block.

import {
  to = truenas_network_config.this
  id = "1"
}

resource "truenas_network_config" "this" {
  hostname    = "nas"
  domain      = "rye.ninja"
  ipv4gateway = "10.45.0.1"
  ipv6gateway = ""

  nameserver1 = "10.45.0.1"
  nameserver2 = "1.1.1.1"
  nameserver3 = "8.8.8.8"

  httpproxy = ""
}

# Interfaces are read-only. The provider's truenas_network_interface update
# is broken for these: it resends lag_ports for a bond that already has them
# ("Interface ... is currently in use") and sends an invalid lag_protocol for
# the VLAN, so even a no-op update fails. They carry the management address
# (bond0) and are best left to the TrueNAS UI anyway. Current layout:
#   bond0  LACP over enp3s0f0np0 + enp3s0f1np1, MTU 1500, IPv6 autoconf,
#          10.45.0.2/16 and fd97:45c2:b3a1:100::1000/64
#   vlan5  VLAN tag 5 on bond0, IPv4 DHCP
#   eno1, eno2: unused
data "truenas_network_interface" "bond0" {
  id = "bond0"
}

data "truenas_network_interface" "vlan5" {
  id = "vlan5"
}

# Forget (without destroying) the interfaces adopted by earlier attempts.
removed {
  from = truenas_network_interface.bond0
  lifecycle { destroy = false }
}

removed {
  from = truenas_network_interface.vlan5
  lifecycle { destroy = false }
}
