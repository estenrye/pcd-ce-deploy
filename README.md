# Running a Lab Grade PCD CE Deployment.

I wanted to do a write-up describing how I build my PCD CE lab
environment.  Let's start with the hardware I have in my lab.

**Unifi Dream Machine SE (UDM-SE)**

This is my home router and firewall.  It has a built-in 2.5GbE switch and two 10GbE SFP+ ports.  I have a 10GbE SFP+ DAC cable that connects to my aggegation switch.  The UDM-SE is running the latest Unifi OS.

**USW Pro Aggregation Switch**

This is a 28 port 10Gb SFP+ aggregation switch.  It has 4 25Gb SFP28 ports.  This is my core switch that connects all of my servers and storage together.

**MinisForum MS-A2**

This is a small form factor PC that I use as the head node for my PCD CE lab.  It has an AMD Ryzen 9955HX CPU, 64GB of RAM, a 1TB NVMe SSD for the OS drive and 2 4TB NVMe SSDs for the ZFS storage pool I am connnecting to KVM.  The MS-A2 is connected to the aggregation switch via two 10GbE SFP+ DAC cables in a LACP bond.  The MS-A2 is running Ubuntu 22.04 LTS and KVM.  I have a number of VMs running on this including my NAT64 and DNS64 server, a kubernetes cluster for services I want operational independently of PCD CE, and a VM for running the PCD CE management plane.  The storage pool is configured to take VM snapshots and replicate them to my NAS for backup and recovery.

**TrueNAS Scale 25.10 Network Attached Storage (NAS)**

This is the storage server for my PCD CE lab.  It has 2 10GbE SFP+ ports and is connected to the aggregation switch via two 10GbE SFP+ DAC cables in a LACP bond.  The NAS is running TrueNAS Scale 25.10 and has a ZFS storage pool configured with 4 8TB SAS3 SSDs in a 2 x MIRROR | 2 wide ZFS pool configuration.