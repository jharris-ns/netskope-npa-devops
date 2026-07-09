output "app_names" {
  description = "Netskope app names created by this persona"
  value       = { for k, v in netskope_npa_private_app.this : k => v.private_app_name }
}

output "app_ids" {
  description = "Map of app key to Netskope private app ID"
  value       = { for k, v in netskope_npa_private_app.this : k => v.private_app_id }
}

output "active_publishers" {
  description = "Publishers currently active for this role (from registry)"
  value       = local.app_publishers
}

output "publisher_role" {
  description = "Publisher role being used"
  value       = var.publisher_role
}

output "active_publisher_names" {
  description = "Publisher names currently active for this role"
  value       = local.active_publisher_names
}
