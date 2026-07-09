# IAM for NPA Publisher VM instances.
#
# One service account is shared by all publisher VMs in this deployment.
# Each publisher VM is granted access only to its own registration token secret
# (not a project-wide secretAccessor binding) — this is the per-secret scoping
# described in the design doc and GCP reference repo.

# ── Publisher VM service account ──────────────────────────────────────────────

resource "google_service_account" "publisher" {
  account_id   = "npa-publisher-sa"
  display_name = "NPA Publisher VM Service Account"
  description  = "Service account for NPA Publisher VM instances. Managed by Terraform."
  project      = var.gcp_project_id
}

# ── Project-level roles ───────────────────────────────────────────────────────

resource "google_project_iam_member" "publisher_log_writer" {
  project = var.gcp_project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.publisher.email}"
}

resource "google_project_iam_member" "publisher_metric_writer" {
  project = var.gcp_project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.publisher.email}"
}

# Required only when the Ops Agent is installed (enable_monitoring = true).
resource "google_project_iam_member" "publisher_resource_metadata_writer" {
  count   = var.enable_monitoring ? 1 : 0
  project = var.gcp_project_id
  role    = "roles/stackdriver.resourceMetadata.writer"
  member  = "serviceAccount:${google_service_account.publisher.email}"
}

# ── Per-secret IAM bindings ───────────────────────────────────────────────────
# Each publisher VM's service account is granted secretAccessor on its own
# registration token secret only — not project-wide. This means a compromised
# publisher can only read its own token (which is already consumed after
# registration anyway).
#
# Defined here rather than in secrets.tf to keep all IAM in one place.

resource "google_secret_manager_secret_iam_member" "publisher_token_access" {
  for_each  = local.publishers
  project   = var.gcp_project_id
  secret_id = google_secret_manager_secret.publisher_token[each.key].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.publisher.email}"
}
