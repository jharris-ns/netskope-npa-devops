terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
    netskope = {
      source  = "netskopeoss/netskope"
      version = ">= 0.4.2"
    }
  }

  # Uncomment and configure to use GCS remote state (recommended for production).
  # See docs/self-service-devops-for-netskope-npa.docx §STATE_MANAGEMENT for guidance.
  #
  # backend "gcs" {
  #   bucket = "npa-publisher-terraform-state-YOUR_PROJECT_ID"
  #   prefix = "npa-publishers"
  #
  #   # Optional: CMEK encryption key for the state object.
  #   # encryption_key = "projects/PROJECT_ID/locations/REGION/keyRings/KEYRING/cryptoKeys/KEY"
  # }
}
