variable "dev_project_id" {
  description = "Google Cloud project ID for the dev environment."
  type        = string
}

variable "prod_project_id" {
  description = "Google Cloud project ID for the prod environment."
  type        = string
}

variable "github_repository" {
  description = "GitHub repository in the form owner/repo that will publish release artifacts."
  type        = string
}

variable "required_apis" {
  description = "List of APIs to enable in both projects."
  type        = list(string)
  default = [
    "cloudfunctions.googleapis.com",
    "eventarc.googleapis.com",
    "run.googleapis.com",
    "pubsub.googleapis.com",
    "cloudscheduler.googleapis.com",
    "logging.googleapis.com",
    "cloudbuild.googleapis.com",
    "storage.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com"
  ]
}

variable "state_bucket_location" {
  description = "Location for the Terraform state buckets."
  type        = string
  default     = "us-central1"
}

variable "release_bucket_location" {
  description = "Location for the release artifact bucket."
  type        = string
  default     = "us-central1"
}

variable "dev_state_bucket_name" {
  description = "Name for the dev Terraform state bucket."
  type        = string
  default     = "tfstate-payments-test-runner-dev"
}

variable "prod_state_bucket_name" {
  description = "Name for the prod Terraform state bucket."
  type        = string
  default     = "tfstate-payments-test-runner-prod"
}

variable "release_bucket_name" {
  description = "Name for the release artifact bucket in the dev project."
  type        = string
  default     = "code-releases-payments-dev"
}

variable "release_service_account_id" {
  description = "Service account ID (without domain) used for GitHub artifact uploads."
  type        = string
  default     = "release-artifacts"
}

variable "release_service_account_display_name" {
  description = "Display name for the release service account."
  type        = string
  default     = "GitHub Artifact Releaser"
}

variable "workload_identity_pool_id" {
  description = "ID to assign to the Workload Identity Pool (dev project)."
  type        = string
  default     = "github-actions"
}

variable "workload_identity_pool_display_name" {
  description = "Display name for the Workload Identity Pool."
  type        = string
  default     = "GitHub Actions Pool"
}

variable "workload_identity_pool_provider_id" {
  description = "ID to assign to the Workload Identity Pool provider."
  type        = string
  default     = "github"
}

variable "workload_identity_pool_provider_display_name" {
  description = "Display name for the Workload Identity Pool provider."
  type        = string
  default     = "GitHub Provider"
}
