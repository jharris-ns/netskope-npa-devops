# VPC, subnet, Cloud Router, and Cloud NAT for NPA publisher instances.
#
# All resources are conditional on var.create_vpc = true. When false, provide
# existing_network_self_link and existing_subnet_self_links — the existing
# subnet must already have Private Google Access enabled and a Cloud NAT attached.
#
# Design:
#   - No external IP on VMs (access_config omitted from network_interface)
#   - Outbound internet (to Netskope) via Cloud NAT on this router
#   - GCP API access (Secret Manager, Monitoring) via Private Google Access on subnet
#   - IAP TCP tunnelling for SSH — no bastion host or VPN needed

# ── VPC ───────────────────────────────────────────────────────────────────────

resource "google_compute_network" "vpc" {
  count                   = var.create_vpc ? 1 : 0
  name                    = "npa-publishers"
  auto_create_subnetworks = false
  description             = "VPC for Netskope NPA Publisher instances. Managed by Terraform."
}

# ── Subnet ────────────────────────────────────────────────────────────────────

resource "google_compute_subnetwork" "publisher" {
  count                    = var.create_vpc ? 1 : 0
  name                     = "npa-publishers"
  ip_cidr_range            = var.subnet_cidr
  region                   = var.gcp_region
  network                  = google_compute_network.vpc[0].id
  private_ip_google_access = true # Required: VMs use metadata server to reach Secret Manager
  description              = "Publisher subnet with Private Google Access. Managed by Terraform."
}

# ── Cloud Router ──────────────────────────────────────────────────────────────

resource "google_compute_router" "publisher" {
  count   = var.create_vpc ? 1 : 0
  name    = "npa-publishers"
  region  = var.gcp_region
  network = google_compute_network.vpc[0].id
}

# ── Cloud NAT ─────────────────────────────────────────────────────────────────
# Provides outbound internet for publisher VMs (no external IP on the VMs).
# The publisher bootstrap script pulls the container image from the internet;
# the running publisher connects outbound to the Netskope tenant.

resource "google_compute_router_nat" "publisher" {
  count                              = var.create_vpc ? 1 : 0
  name                               = "npa-publishers"
  router                             = google_compute_router.publisher[0].name
  region                             = var.gcp_region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# ── Firewall: allow IAP TCP tunnelling for SSH ─────────────────────────────────
# Allows SSH from the IAP address range only — no public SSH exposure.
# Use: gcloud compute ssh INSTANCE --tunnel-through-iap --zone ZONE

resource "google_compute_firewall" "allow_iap_ssh" {
  count   = var.create_vpc ? 1 : 0
  name    = "npa-publishers-allow-iap-ssh"
  network = google_compute_network.vpc[0].name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"] # IAP TCP forwarding address range
  target_tags   = ["npa-publisher"]
  description   = "Allow IAP TCP tunnelling for SSH to publisher instances."
}

# ── Firewall: deny all other ingress (default deny) ───────────────────────────

resource "google_compute_firewall" "deny_all_ingress" {
  count     = var.create_vpc ? 1 : 0
  name      = "npa-publishers-deny-all-ingress"
  network   = google_compute_network.vpc[0].name
  priority  = 65534
  direction = "INGRESS"

  deny {
    protocol = "all"
  }

  source_ranges = ["0.0.0.0/0"]
  description   = "Deny all ingress not explicitly allowed. Publishers initiate outbound connections only."
}
