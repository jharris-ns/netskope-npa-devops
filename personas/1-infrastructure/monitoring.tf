# Cloud Monitoring — log-based alerting for publisher startup failures.
# All resources are conditional on var.enable_monitoring = true.
#
# To enable: set enable_monitoring = true in terraform.tfvars and re-apply.
# The Ops Agent is installed on the VM by the startup script (startup.sh.tftpl)
# when this flag is set, before bootstrap.sh runs.

# ── Log-based metric: startup script errors ───────────────────────────────────

resource "google_logging_metric" "publisher_startup_error" {
  count       = var.enable_monitoring ? 1 : 0
  name        = "npa-publisher-startup-error"
  description = "Counts ERROR-level entries from the NPA Publisher startup script."
  project     = var.gcp_project_id

  filter = <<-EOT
    resource.type="gce_instance"
    logName="projects/${var.gcp_project_id}/logs/google-startup-scripts"
    severity>=ERROR
    labels."compute.googleapis.com/resource_name"=~"^us-west-dc1-"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
    labels {
      key         = "instance_name"
      value_type  = "STRING"
      description = "Publisher instance that logged the error"
    }
  }

  label_extractors = {
    "instance_name" = "EXTRACT(labels.\"compute.googleapis.com/resource_name\")"
  }
}

# ── Alerting policy ───────────────────────────────────────────────────────────

resource "google_monitoring_alert_policy" "publisher_startup_error" {
  count        = var.enable_monitoring ? 1 : 0
  display_name = "NPA Publisher Startup Error"
  project      = var.gcp_project_id
  combiner     = "OR"

  conditions {
    display_name = "Startup script error detected"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.publisher_startup_error[0].name}\" AND resource.type=\"gce_instance\""
      duration        = "60s"
      comparison      = "COMPARISON_GT"
      threshold_value = 0

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_RATE"
      }
    }
  }

  notification_channels = var.alert_notification_channels

  alert_strategy {
    auto_close = "604800s" # 7 days
  }

  documentation {
    content   = "An NPA Publisher VM logged an error during startup. Check the startup script logs: `gcloud logging read 'resource.type=\"gce_instance\" AND logName:\"google-startup-scripts\" AND severity>=ERROR' --project=${var.gcp_project_id} --limit=20`"
    mime_type = "text/markdown"
  }
}
