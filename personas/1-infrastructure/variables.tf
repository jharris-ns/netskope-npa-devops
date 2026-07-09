# ── GCP ───────────────────────────────────────────────────────────────────────

variable "gcp_project_id" {
  type        = string
  description = "GCP project ID where publishers will be deployed. Set via TF_VAR_gcp_project_id (see scripts/set-env.sh)."
}

variable "gcp_region" {
  type        = string
  description = "GCP region for publisher deployment."
  default     = "us-west1"
}

variable "zones" {
  type        = list(string)
  description = "Specific GCP zones for publisher distribution within gcp_region. If empty, Terraform auto-selects available zones."
  default     = []
}

# ── Netskope ──────────────────────────────────────────────────────────────────

variable "netskope_server_url" {
  type        = string
  description = "Netskope tenant API base URL including /api/v2 (e.g. https://mytenant.goskope.com/api/v2). Set via TF_VAR_netskope_server_url (see scripts/set-env.sh)."
  sensitive   = true
}

variable "netskope_api_key" {
  type        = string
  description = "Netskope REST API token with Infrastructure Management scope. Set via TF_VAR_netskope_api_key (see scripts/set-env.sh)."
  sensitive   = true
}

# ── Publishers ────────────────────────────────────────────────────────────────

variable "publishers" {
  type = map(object({
    name = string
  }))
  description = <<-EOT
    Map of publishers to create. The map key is the Terraform resource identifier
    (used in state and for_each); `name` is the publisher name registered with Netskope
    and referenced in shared/publisher-registry.yaml.

    Keys are sorted lexicographically for zone distribution — ensure your key names
    produce a stable sort order when adding or removing publishers.
  EOT
  default = {
    primary = {
      name = "us-west-dc1-primary"
    }
    secondary = {
      name = "us-west-dc1-secondary"
    }
  }
}

variable "publisher_machine_type" {
  type        = string
  description = "GCP machine type for publisher VM instances."
  default     = "n2-standard-2"
  validation {
    condition = contains([
      "e2-medium", "e2-standard-2", "e2-standard-4",
      "n2-standard-2", "n2-standard-4", "n2-standard-8",
      "n2-highmem-2", "n2-highmem-4",
      "c2-standard-4", "c2-standard-8",
    ], var.publisher_machine_type)
    error_message = "publisher_machine_type must be one of the supported GCP machine types listed in variables.tf."
  }
}

variable "publisher_image_self_link" {
  type        = string
  description = "Full self-link of a custom GCP Compute Engine image. If empty (default), Ubuntu 22.04 LTS is used."
  default     = ""
}

# ── Networking ────────────────────────────────────────────────────────────────

variable "create_vpc" {
  type        = bool
  description = "If true, create a new VPC, subnet, Cloud Router, and Cloud NAT. If false, provide existing_network_self_link and existing_subnet_self_links."
  default     = true
}

variable "subnet_cidr" {
  type        = string
  description = "CIDR range for the publisher subnet. Only used when create_vpc = true."
  default     = "10.0.0.0/24"
  validation {
    condition     = can(cidrhost(var.subnet_cidr, 0))
    error_message = "subnet_cidr must be a valid CIDR block (e.g. 10.0.0.0/24)."
  }
}

variable "existing_network_self_link" {
  type        = string
  description = "Self-link of an existing GCP VPC network. Required when create_vpc = false."
  default     = null
}

variable "existing_subnet_self_links" {
  type        = list(string)
  description = "Self-links of existing subnets with Private Google Access and Cloud NAT already configured. Required when create_vpc = false."
  default     = []
}

# ── Monitoring ────────────────────────────────────────────────────────────────

variable "enable_monitoring" {
  type        = bool
  description = "If true, install the Google Cloud Ops Agent on publisher instances and create log-based alerting."
  default     = false
}

variable "alert_notification_channels" {
  type        = list(string)
  description = "List of Cloud Monitoring notification channel IDs to alert on publisher startup failures. Only used when enable_monitoring = true."
  default     = []
}

# ── Labels / metadata ─────────────────────────────────────────────────────────

variable "environment" {
  type        = string
  description = "Environment label applied to all GCP resources."
  default     = "production"
  validation {
    condition     = contains(["production", "staging", "development", "test"], var.environment)
    error_message = "environment must be one of: production, staging, development, test."
  }
}

variable "cost_center" {
  type        = string
  description = "Cost center label for billing allocation."
  default     = "it-operations"
}

variable "project_label" {
  type        = string
  description = "Project label applied to all GCP resources."
  default     = "npa-publisher"
}

variable "additional_labels" {
  type        = map(string)
  description = "Additional GCP labels to apply to all resources. Values must be lowercase."
  default     = {}
}
