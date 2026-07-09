# verify.tf — pre-destroy safety check for publisher cycling (Section 8.6.5).
#
# Usage during a cycle (stage 8 of cycle-publisher.sh):
#   terraform apply -var="retiring_publisher_name=us-west-dc1-primary"
#   terraform output apps_blocking_retirement
#
# If the output is non-empty, apps are still associated with the retiring publisher.
# Do NOT destroy it until all apps have been reassociated via the Dev-team apply
# triggered by updating shared/publisher-registry.yaml.
#
# When not cycling, leave retiring_publisher_name at its default ("") — the
# data source still runs but apps_blocking_retirement will always be [].

variable "retiring_publisher_name" {
  description = "Set during a cycle to the publisher name being retired; empty string otherwise."
  type        = string
  default     = ""
}

data "netskope_npa_private_apps_list" "all" {
  count = var.retiring_publisher_name != "" ? 1 : 0
}

locals {
  apps_blocking_retirement = var.retiring_publisher_name == "" ? [] : [
    for app in data.netskope_npa_private_apps_list.all[0].private_apps :
    app.private_app_name
    if length([
      for pub in app.publishers :
      pub if pub.publisher_name == var.retiring_publisher_name
    ]) > 0
  ]
}

output "apps_blocking_retirement" {
  description = "Apps still associated with the retiring publisher. Must be [] before destroying it."
  value       = local.apps_blocking_retirement
}
