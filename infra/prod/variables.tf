variable "project_id" {}

variable "artifact_bucket" {
  description = "GCS bucket that stores release artifacts for the processors."
}

variable "functions" {
  description = "Processor configuration keyed by function name."
  type = map(object({
    artifact_object = string
    entry_point     = string
    schedule        = string
    regions         = list(string)
  }))
}

variable "scheduler_time_zone" {
  description = "IANA time zone identifier used by Cloud Scheduler jobs."
  type        = string
  default     = "America/Denver"
}
