output "controlplane_address" {
  description = "IPv6 address of the control-plane node."
  value       = local.controlplane_address
}

output "cluster_endpoint" {
  description = "Kubernetes API server endpoint."
  value       = "https://[${local.controlplane_address}]:6443"
}

output "talosconfig" {
  description = "talosctl client config. Save with: tofu output -raw talosconfig > talosconfig, then talosctl --talosconfig talosconfig ..."
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}

output "kubeconfig" {
  description = "kubectl client config. Save with: tofu output -raw kubeconfig > kubeconfig, then kubectl --kubeconfig kubeconfig ..."
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}
