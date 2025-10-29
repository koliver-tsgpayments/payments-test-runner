variable "project_id" {}
variable "artifact_bucket" {}

# Pin artifacts per processor (uploaded by CI to the dev project's bucket)
variable "tsg_artifact_object" {
  description = "GCS object path for TSG function zip (e.g. releases/tsg-<tag>.zip)"
}

variable "worldpay_artifact_object" {
  description = "GCS object path for Worldpay function zip (e.g. releases/worldpay-<tag>.zip)"
}

# Regions (simple: one region for dev)
variable "dev_region" {
  default = "us-central1"
}
