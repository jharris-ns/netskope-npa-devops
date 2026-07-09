# Netskope publisher records and registration tokens.
#
# Each publisher VM needs a publisher record and a single-use registration token.
# The token is stored in Secret Manager and consumed by the VM startup script
# to call the npa_publisher_wizard — after that, the token is exhausted.
#
# Relationship to shared/publisher-registry.yaml:
#   This file creates the Netskope-side records. The publisher-registry.yaml file
#   maps role names (us-west-primary, us-west-secondary) to the publisher names
#   created here. During a cycling operation, cycle-publisher.sh edits the registry
#   manually at each stage — Terraform does not auto-generate it, so the registry
#   change is a discrete, visible step (the teaching point of Section 8.6.4).

resource "netskope_npa_publisher" "this" {
  for_each       = local.publishers
  publisher_name = each.value.name
}

resource "netskope_npa_publisher_token" "this" {
  for_each     = local.publishers
  publisher_id = netskope_npa_publisher.this[each.key].publisher_id
}
