# Kubernetes Image Builder

This tofu module is used to build and manage Kubernetes images for my PCD environment.

## Features

- Installs an Ubuntu 24.04 base image
- Provisions an Ubuntu 24.04 server image and configures it for building a PCD-K compliant image.
- Builds openstack images for the PCD-K environment.

## References

- [PCD Docs: Kubernetes Operating System Image Management](https://docs.platform9.com/private-cloud-director/kubernetes-clusters/kubernetes-operating-system-image-management)
- [The Image Builder Book: OpenStack Provider](https://image-builder.sigs.k8s.io/capi/providers/openstack)
- [The Image Builder Book: Kubernetes Image Builder](https://image-builder.sigs.k8s.io/introduction.html)
- [Github: kubernetes-sigs/image-builder](https://github.com/kubernetes-sigs/image-builder)
## Usage

```sh
tofu init
tofu plan -out=plan.out
tofu apply plan.out
```

Spec: [docs/k8s-image-builder-spec.md](../docs/k8s-image-builder-spec.md).

`kubernetes_versions` (see `variables.tf`) lists one image per entry, each
with a Kubernetes `minor`, an `os` and an optional pinned `patch`. The default
is 1.32 through 1.37 on Ubuntu 24.04, latest patch of each.

How it works: a builder VM boots from an Ubuntu 24.04 cloud image, cloud-init
installs the image-builder dependencies, and each image is built with
`make build-qemu-<os>` and uploaded to Glance from the builder with
`k8s_version=<minor>` set. Builds run one at a time (flock on the builder).

Behavior to know about:

- Images are never deleted by tofu. A new patch release or `image_builder_ref`
  produces a new image name next to the old one; `tofu destroy` leaves images.
- `builder_enabled = false` destroys the builder VM, keeping the images.
- The builder needs `/dev/kvm` (nested virtualization) and reach to github.com,
  pkgs.k8s.io, dl.k8s.io and registry.k8s.io (NAT64/DNS64 on an IPv6-only
  network; set `builder_dns64_servers` if the subnet's DNS isn't DNS64). Both
  are checked before any build starts.
- Builder credentials: the PCD admin login is written to a 0600 env file on the
  builder for the duration of each build, and is also in tofu state.
- `workstation` upload mode from the spec is not implemented.
