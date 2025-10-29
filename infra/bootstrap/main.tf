terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.dev_project_id
}

provider "google-beta" {
  project = var.dev_project_id
}

provider "google" {
  alias   = "prod"
  project = var.prod_project_id
}

data "google_project" "dev" {
  project_id = var.dev_project_id
}

data "google_project" "prod" {
  provider   = google.prod
  project_id = var.prod_project_id
}

resource "google_project_service" "dev" {
  for_each           = toset(var.required_apis)
  service            = each.value
  disable_on_destroy = false
}

resource "google_project_service" "prod" {
  provider           = google.prod
  for_each           = toset(var.required_apis)
  service            = each.value
  disable_on_destroy = false
}

resource "google_storage_bucket" "dev_state" {
  name     = var.dev_state_bucket_name
  project  = var.dev_project_id
  location = var.state_bucket_location

  uniform_bucket_level_access = true
  force_destroy               = false

  versioning {
    enabled = true
  }

  depends_on = [
    google_project_service.dev["storage.googleapis.com"]
  ]
}

resource "google_storage_bucket" "prod_state" {
  provider = google.prod

  name     = var.prod_state_bucket_name
  project  = var.prod_project_id
  location = var.state_bucket_location

  uniform_bucket_level_access = true
  force_destroy               = false

  versioning {
    enabled = true
  }

  depends_on = [
    google_project_service.prod["storage.googleapis.com"]
  ]
}

resource "google_storage_bucket" "release" {
  name     = var.release_bucket_name
  project  = var.dev_project_id
  location = var.release_bucket_location

  uniform_bucket_level_access = true
  force_destroy               = false

  versioning {
    enabled = true
  }

  depends_on = [
    google_project_service.dev["storage.googleapis.com"]
  ]
}

resource "google_storage_bucket_iam_member" "release_writer_releaser" {
  bucket = google_storage_bucket.release.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.releaser.email}"
}

resource "google_storage_bucket_iam_member" "release_viewer_dev_cloud_build" {
  bucket = google_storage_bucket.release.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${data.google_project.dev.number}@cloudbuild.gserviceaccount.com"
}

resource "google_storage_bucket_iam_member" "release_viewer_prod_cloud_build" {
  bucket = google_storage_bucket.release.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${data.google_project.prod.number}@cloudbuild.gserviceaccount.com"
}

resource "google_service_account" "releaser" {
  account_id   = var.release_service_account_id
  display_name = var.release_service_account_display_name
  project      = var.dev_project_id
}

resource "google_iam_workload_identity_pool" "github" {
  provider                  = google-beta
  project                   = var.dev_project_id
  workload_identity_pool_id = var.workload_identity_pool_id
  display_name              = var.workload_identity_pool_display_name
  description               = "Pool for GitHub Actions deployments"
}

resource "google_iam_workload_identity_pool_provider" "github" {
  provider                           = google-beta
  project                            = var.dev_project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = var.workload_identity_pool_provider_id

  display_name = var.workload_identity_pool_provider_display_name
  description  = "Workload Identity Federation provider for GitHub Actions"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.actor"      = "assertion.actor"
    "attribute.aud"        = "assertion.aud"
    "attribute.repository" = "assertion.repository"
  }

  attribute_condition = "attribute.repository==\"${var.github_repository}\""

  oidc {
    issuer_uri        = "https://token.actions.githubusercontent.com"
    allowed_audiences = ["https://github.com/${var.github_repository}"]
  }
}

resource "google_service_account_iam_member" "releaser_wif_binding" {
  service_account_id = google_service_account.releaser.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/projects/${data.google_project.dev.number}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.github.workload_identity_pool_id}/attribute.repository/${var.github_repository}"
}
