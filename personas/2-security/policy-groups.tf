# Dedicated policy group for all Terraform-managed NPA rules.
#
# Best practice: isolate Terraform-managed rules in their own policy group so
# that manually created rules in the Netskope console do not interfere with
# this configuration and are not silently overwritten by terraform apply.
#
# All rule resources in this persona set group_id = netskope_npa_policy_groups.terraform_managed.id
#
# NOTE: If your tenant already has a "Terraform-Managed" policy group created
# manually, import it before applying:
#   terraform import netskope_npa_policy_groups.terraform_managed <group_id>

data "netskope_npa_policy_groups_list" "existing" {}

output "debug_existing_groups" {
  value = [
    for g in data.netskope_npa_policy_groups_list.existing.data : {
      id   = g.id
      name = g.group_name
    }
  ]
}

resource "netskope_npa_policy_groups" "terraform_managed" {
  group_name  = "Terraform-NPA"
  group_order = {
    group_id = data.netskope_npa_policy_groups_list.existing.data[0].id
    order    = "after"
  }
}
