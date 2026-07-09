output "policy_group_id" {
  description = "ID of the Terraform-Managed policy group"
  value       = netskope_npa_policy_groups.terraform_managed.id
}

output "apps_by_tier" {
  description = "Apps currently visible per tier (from data source — reflects live tenant state)"
  value = {
    web_tier        = local.web_tier_apps
    database_tier   = local.database_tier_apps
    infrastructure  = local.infrastructure_apps
    all             = local.all_app_names
  }
}

output "rules_created" {
  description = "Which rules were created (false = count guard triggered, no apps for that tier yet)"
  value = {
    deny_blocked_groups  = length(netskope_npa_rules.deny_blocked_groups) > 0
    admin_web_tier       = length(netskope_npa_rules.admin_web_tier) > 0
    admin_database_tier  = length(netskope_npa_rules.admin_database_tier) > 0
    admin_infrastructure = length(netskope_npa_rules.admin_infrastructure) > 0
    web_tier_access      = length(netskope_npa_rules.web_tier_access) > 0
    database_tier_access = length(netskope_npa_rules.database_tier_access) > 0
    infrastructure_access = length(netskope_npa_rules.infrastructure_access) > 0
    deny_all             = length(netskope_npa_rules.deny_all) > 0
  }
}

output "approved_tiers" {
  description = "Approved tiers read from shared/tag-taxonomy.yaml"
  value       = local.approved_tiers
}
