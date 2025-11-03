terraform {
  required_version = ">= 1.6.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
}

locals {
  env       = "prod"
  runtime   = "python312"
  time_zone = var.scheduler_time_zone

  function_targets = {
    for item in flatten([
      for processor_name, processor in var.functions : [
        for region in processor.regions : {
          key             = "${processor_name}:${region}"
          processor_name  = processor_name
          region          = region
          entry_point     = processor.entry_point
          artifact_object = processor.artifact_object
          schedule        = processor.schedule
        }
      ]
    ]) : item.key => item
  }
}

resource "google_pubsub_topic" "processor" {
  for_each = local.function_targets

  name = "${each.value.processor_name}-topic-${each.value.region}"
}

resource "google_cloudfunctions2_function" "processor" {
  for_each = local.function_targets

  name     = "${each.value.processor_name}-${each.value.region}"
  location = each.value.region
  labels = {
    env       = local.env
    service   = "test-runner"
    processor = each.value.processor_name
  }

  build_config {
    runtime     = local.runtime
    entry_point = each.value.entry_point
    source {
      storage_source {
        bucket = var.artifact_bucket
        object = each.value.artifact_object
      }
    }
  }

  service_config {
    available_memory = "256M"
    timeout_seconds  = 60
    environment_variables = {
      ENV    = local.env
      REGION = each.value.region
    }
  }

  event_trigger {
    trigger_region = each.value.region
    event_type     = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic   = google_pubsub_topic.processor[each.key].id
    retry_policy   = "RETRY_POLICY_RETRY"
  }
}

resource "google_cloud_scheduler_job" "processor" {
  for_each = local.function_targets

  name      = "${each.value.processor_name}-cron-${each.value.region}"
  schedule  = each.value.schedule
  region    = each.value.region
  time_zone = local.time_zone

  pubsub_target {
    topic_name = google_pubsub_topic.processor[each.key].id
    data       = base64encode(jsonencode({ action = "run", env = local.env }))
  }
}

# BigQuery dataset for probe logs
resource "google_bigquery_dataset" "probe" {
  dataset_id                  = var.bq_dataset_id
  location                    = var.bq_location
  default_table_expiration_ms = var.bq_table_expiration_days == null ? null : var.bq_table_expiration_days * 24 * 60 * 60 * 1000

  labels = {
    env = local.env
  }
}

# Log Router sink exporting only probe envelopes to BigQuery
resource "google_logging_project_sink" "probe_to_bq" {
  count = var.enable_bq_sink ? 1 : 0

  name             = "probe-to-bq"
  destination      = "bigquery.googleapis.com/projects/${var.project_id}/datasets/${var.bq_dataset_id}"
  filter           = "jsonPayload.source=\"gcp.payment-probe\" AND jsonPayload.event.schema_version=\"v1\""

  bigquery_options {
    use_partitioned_tables = var.bq_sink_use_partitioned_tables
  }
}

# Grant sink writer identity permissions on the dataset
resource "google_bigquery_dataset_iam_member" "sink_writer" {
  count = var.enable_bq_sink ? 1 : 0

  dataset_id = google_bigquery_dataset.probe.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = google_logging_project_sink.probe_to_bq[0].writer_identity
}

# Pub/Sub topics for probe logs and future DLQ use (always created)
resource "google_pubsub_topic" "probe_logs" {
  name = var.pubsub_topic_name
}

resource "google_pubsub_topic" "probe_logs_dlq" {
  name = var.pubsub_dlq_topic_name
}

# Log Router sink exporting only probe envelopes to Pub/Sub (toggleable)
resource "google_logging_project_sink" "probe_to_pubsub" {
  count = var.enable_pubsub_sink ? 1 : 0

  name        = "probe-to-pubsub"
  destination = "pubsub.googleapis.com/${google_pubsub_topic.probe_logs.id}"
  filter      = "jsonPayload.source=\"gcp.payment-probe\" AND jsonPayload.event.schema_version=\"v1\""
}

# Grant sink writer identity permission to publish to the topic
resource "google_pubsub_topic_iam_member" "sink_publisher" {
  count = var.enable_pubsub_sink ? 1 : 0

  topic  = google_pubsub_topic.probe_logs.name
  role   = "roles/pubsub.publisher"
  member = google_logging_project_sink.probe_to_pubsub[0].writer_identity
}
