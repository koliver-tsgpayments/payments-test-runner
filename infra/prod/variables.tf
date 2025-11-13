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

variable "enable_splunk_forwarder" {
  description = "Enable forwarding probe envelopes from Pub/Sub to Splunk via Dataflow."
  type        = bool
  default     = false
}

variable "splunk_hec_url" {
  description = "Splunk HEC endpoint URL (e.g. https://splunk.example.com:8088)."
  type        = string
  default     = null

  validation {
    condition     = var.splunk_hec_url == null || can(regex("^https://[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?$", var.splunk_hec_url))
    error_message = "splunk_hec_url must be https://<fqdn[:port]> with no trailing slash or path."
  }
}

variable "splunk_hec_token" {
  description = "Splunk HEC token used by the forwarder."
  type        = string
  sensitive   = true
  default     = null
}

variable "splunk_root_ca_gcs_path" {
  description = "Optional Cloud Storage path to a PEM-encoded root certificate for Splunk HEC."
  type        = string
  default     = null
}

variable "splunk_index" {
  description = "Splunk index override (defaults to \"payments\")."
  type        = string
  default     = "payments"
}

variable "splunk_source" {
  description = "Optional Splunk source override."
  type        = string
  default     = null
}

variable "splunk_sourcetype" {
  description = "Splunk sourcetype value applied to forwarded events."
  type        = string
  default     = "payment_probe"
}

variable "splunk_batch_count" {
  description = "Number of events per batch sent to Splunk."
  type        = number
  default     = 500
}

variable "splunk_batch_bytes" {
  description = "Maximum batch size in bytes when sending to Splunk."
  type        = number
  default     = 1048576
}

variable "splunk_batch_interval_sec" {
  description = "Maximum number of seconds to wait before flushing a partial batch."
  type        = number
  default     = 5
}

variable "splunk_max_workers" {
  description = "Maximum number of Dataflow workers for the Splunk forwarder."
  type        = number
  default     = 3
}

variable "splunk_machine_type" {
  description = "Dataflow worker machine type used by the Splunk forwarder."
  type        = string
  default     = "n1-standard-2"
}

variable "dataflow_region" {
  description = "Region to run the Splunk forwarder Dataflow job (null for default)."
  type        = string
  default     = null
}

variable "pubsub_subscription_name" {
  description = "Dedicated subscription name on probe-logs for the Splunk forwarder."
  type        = string
  default     = "probe-logs-splunk"
}
