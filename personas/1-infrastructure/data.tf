data "google_project" "current" {}

data "google_compute_zones" "available" {
  region = var.gcp_region
  status = "UP"
}

# Ubuntu 22.04 LTS — only fetched when no custom image is provided.
data "google_compute_image" "ubuntu" {
  count   = var.publisher_image_self_link == "" ? 1 : 0
  family  = "ubuntu-2204-lts"
  project = "ubuntu-os-cloud"
}
