# Centralized data sources and tier-filtered locals.
# All rule files reference these locals — data sources are fetched once.

# ── Tag taxonomy (Security-owned source of truth) ─────────────────────────────
# Read directly from shared/tag-taxonomy.yaml so this persona stays in sync
# with the approved tier list without manual duplication.
locals {
  taxonomy       = yamldecode(file("${path.module}/../../shared/tag-taxonomy.yaml"))
  approved_tiers = local.taxonomy.approved_tiers  # ["web-tier", "database-tier", "infrastructure"]
}

# ── Netskope data sources ─────────────────────────────────────────────────────

data "netskope_npa_private_apps_list" "all" {}

data "netskope_npa_policy_groups_list" "all" {}

# ── App lists filtered by tier tag ────────────────────────────────────────────
# Pattern from terraform-netskope-examples/policy-as-code/data.tf:
#   - coalesce(app.tags, []) guards against apps with null tags
#   - Inner comprehension filters tag objects by tag_name
#   - Result is a plain list(string) of app names — required by netskope_npa_rules
#
# These lists drive the count guards on every rule resource. A rule with an empty
# private_apps list is rejected by the Netskope API, so rules are only created
# when at least one app exists for that tier.

locals {
  web_tier_apps = [
    for app in data.netskope_npa_private_apps_list.all.private_apps :
    app.private_app_name
    if length([
      for tag in coalesce(app.tags, []) :
      tag if tag.tag_name == "web-tier"
    ]) > 0
  ]

  database_tier_apps = [
    for app in data.netskope_npa_private_apps_list.all.private_apps :
    app.private_app_name
    if length([
      for tag in coalesce(app.tags, []) :
      tag if tag.tag_name == "database-tier"
    ]) > 0
  ]

  infrastructure_apps = [
    for app in data.netskope_npa_private_apps_list.all.private_apps :
    app.private_app_name
    if length([
      for tag in coalesce(app.tags, []) :
      tag if tag.tag_name == "infrastructure"
    ]) > 0
  ]

  # All app names — used by the catch-all deny rule and blocked-group rule.
  all_app_names = [
    for app in data.netskope_npa_private_apps_list.all.private_apps :
    app.private_app_name
  ]
}
