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

variable "bq_dataset_id" {
  description = "BigQuery dataset ID for probe logs."
  type        = string
  default     = "payment_probe"
}

variable "bq_location" {
  description = "BigQuery dataset location."
  type        = string
  default     = "US"
}

variable "enable_bq_sink" {
  description = "Enable Log Router sink to BigQuery for probe envelopes."
  type        = bool
  default     = true
}

variable "bq_table_expiration_days" {
  description = "Default table expiration in days for the dataset (null for none)."
  type        = number
  default     = null
}

variable "bq_sink_use_partitioned_tables" {
  description = "When true, the Log Router writes to time-partitioned tables instead of daily sharded tables."
  type        = bool
  default     = true
}

variable "enable_pubsub_sink" {
  description = "Enable Log Router sink to Pub/Sub for probe envelopes."
  type        = bool
  default     = false
}

variable "pubsub_topic_name" {
  description = "Pub/Sub topic name for probe logs."
  type        = string
  default     = "probe-logs"
}

variable "pubsub_dlq_topic_name" {
  description = "Pub/Sub DLQ topic name for future consumers."
  type        = string
  default     = "probe-logs-dlq"
}
