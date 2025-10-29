output "dev_state_bucket" {
  description = "Terraform state bucket for dev."
  value       = google_storage_bucket.dev_state.name
}

output "prod_state_bucket" {
  description = "Terraform state bucket for prod."
  value       = google_storage_bucket.prod_state.name
}

output "release_bucket" {
  description = "Release artifact bucket."
  value       = google_storage_bucket.release.name
}

output "gcp_releaser_service_account" {
  description = "Service account email GitHub Actions should impersonate."
  value       = google_service_account.releaser.email
}

output "gcp_workload_identity_provider" {
  description = "Full resource name for the Workload Identity Provider."
  value       = "projects/${data.google_project.dev.number}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.github.workload_identity_pool_id}/providers/${google_iam_workload_identity_pool_provider.github.workload_identity_pool_provider_id}"
}
