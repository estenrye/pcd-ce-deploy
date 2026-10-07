output "controlplane_addresses" {
  description = "IPv6 addresses of the control-plane nodes (on bgp-net; also their BGP source addresses)."
  value       = local.controlplane_addresses
}

output "worker_addresses" {
  description = "IPv6 addresses of the worker nodes (on bgp-net)."
  value       = local.worker_addresses
}

output "cluster_vip" {
  description = "Floating control-plane VIP that the Kubernetes API endpoint points at."
  value       = local.cluster_vip
}

output "cluster_endpoint" {
  description = "Kubernetes API server endpoint (the control-plane VIP)."
  value       = local.cluster_endpoint
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

output "kms_key_id" {
  description = "ID of the Barbican secret holding the cluster-secrets encryption key, or null when create_kms_key is false."
  value       = one(pcd_keymanager_secret.kms_key[*].id)
}
