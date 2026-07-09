output "publisher_names" {
  description = "Publisher names registered with Netskope (matches entries in shared/publisher-registry.yaml)"
  value       = { for k, v in local.publishers : k => v.name }
}

output "netskope_publisher_ids" {
  description = "Map of publisher key to Netskope publisher ID"
  value       = { for k, v in netskope_npa_publisher.this : k => v.publisher_id }
}

output "publisher_private_ips" {
  description = "Map of publisher name to private IP address"
  value       = { for k, v in google_compute_instance.publisher : k => v.network_interface[0].network_ip }
}

output "publisher_zones" {
  description = "Map of publisher name to GCP zone"
  value       = { for k, v in google_compute_instance.publisher : k => v.zone }
}

output "publisher_service_account_email" {
  description = "Email of the publisher VM service account"
  value       = google_service_account.publisher.email
}

output "iap_ssh_commands" {
  description = "gcloud commands to SSH into each publisher via IAP TCP tunnelling"
  value = {
    for k, v in google_compute_instance.publisher :
    k => "gcloud compute ssh ${v.name} --tunnel-through-iap --zone ${v.zone} --project ${var.gcp_project_id}"
  }
}

output "log_query" {
  description = "Cloud Logging query to view publisher startup script output"
  value       = "gcloud logging read 'resource.type=\"gce_instance\" AND logName:\"google-startup-scripts\"' --project=${var.gcp_project_id} --limit=50"
}

output "network_self_link" {
  description = "Self-link of the VPC network (created or existing)"
  value       = local.network_self_link
}
