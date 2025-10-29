variable "project_id" {}
variable "artifact_bucket" {}

# Pin artifacts per processor (usually promoted tags copied to dev bucket or a shared-infra bucket)
variable "tsg_artifact_object" {
  description = "GCS object path for TSG function zip (e.g. releases/tsg-<tag>.zip)"
}

variable "worldpay_artifact_object" {
  description = "GCS object path for Worldpay function zip (e.g. releases/worldpay-<tag>.zip)"
}

# Prod regions (explicit, no loops)
variable "region_us1" { default = "us-central1" }
variable "region_us2" { default = "us-east4" }
variable "region_latam" { default = "southamerica-east1" } # São Paulo (closest GA LATAM)
