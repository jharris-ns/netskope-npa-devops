# Compute Engine VM instances for NPA Publishers.
#
# Key design decisions (from GCP-NPA-Reference-Architecture-Terraform):
#   - No external IP (network_interface has no access_config block)
#   - Outbound internet via Cloud NAT (vpc.tf)
#   - GCP API access via Private Google Access on subnet (no VPC endpoints needed)
#   - Service account identity used by startup script to read registration token
#   - Shielded VM for boot integrity and vTPM
#   - OS Login replaces SSH key pairs
#   - ignore_changes on startup-script and boot_disk to prevent unintended replacement
#
# To intentionally replace a publisher (e.g. for image updates), use -replace:
#   terraform apply \
#     -replace='netskope_npa_publisher.this["KEY"]' \
#     -replace='netskope_npa_publisher_token.this["KEY"]' \
#     -replace='google_secret_manager_secret_version.publisher_token["KEY"]' \
#     -replace='google_compute_instance.publisher["KEY"]'
#
# IMPORTANT — two-pass destroy:
#   terraform destroy removes GCP resources before Netskope publisher records.
#   GCE instance deletion takes 60-90 seconds; Netskope rejects deleting a publisher
#   still marked "connected". Pass 1 exits with error after removing all GCP resources.
#   Wait ~2 minutes for the publisher to show "disconnected", then run destroy again.
#   See personas/1-infrastructure/README.md § Destroy procedure.

resource "google_compute_instance" "publisher" {
  for_each = local.publishers

  name         = each.value.name
  machine_type = var.publisher_machine_type
  zone         = local.zones[each.value.index % length(local.zones)]
  project      = var.gcp_project_id

  tags   = ["npa-publisher"]
  labels = local.common_labels

  boot_disk {
    initialize_params {
      image = local.publisher_image
      size  = 30
      type  = "pd-ssd"
    }
  }

  network_interface {
    subnetwork = local.subnet_self_links[each.value.index % length(local.subnet_self_links)]
    # No access_config block = no external IP. Outbound internet via Cloud NAT.
  }

  service_account {
    email  = google_service_account.publisher.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  metadata = {
    enable-oslogin = "TRUE"
    startup-script = templatefile("${path.module}/templates/startup.sh.tftpl", {
      enable_monitoring = var.enable_monitoring
      secret_name       = google_secret_manager_secret.publisher_token[each.key].secret_id
      project_id        = var.gcp_project_id
      publisher_name    = each.value.name
    })
  }

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
    preemptible         = false
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  lifecycle {
    ignore_changes = [
      # Do not replace running publishers when the startup script template changes.
      # Running publishers update themselves via Netskope auto-update.
      metadata["startup-script"],
      # Do not replace when the Ubuntu base image reference changes.
      # Use explicit -replace for intentional image replacement (see comment above).
      boot_disk,
    ]
  }

  depends_on = [
    google_secret_manager_secret_iam_member.publisher_token_access,
    google_compute_router_nat.publisher,
  ]
}
