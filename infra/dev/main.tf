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

data "google_project" "current" {
  project_id = var.project_id
}

resource "google_project_service" "required" {
  for_each = toset([
    "dataflow.googleapis.com",
    "compute.googleapis.com",
    "storage.googleapis.com",
    "pubsub.googleapis.com",
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

locals {
  env                      = "dev"
  runtime                  = "python312"
  time_zone                = var.scheduler_time_zone
  splunk_forwarder_enabled = var.enable_splunk_forwarder
  dataflow_region          = coalesce(var.dataflow_region, "us-central1")
  dataflow_service_agent   = "service-${data.google_project.current.number}@dataflow-service-producer-prod.iam.gserviceaccount.com"

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

locals {
  splunk_forwarder_temp_location = local.splunk_forwarder_enabled ? format("gs://%s/splunk-forwarder-temp", var.dataflow_staging_bucket) : "gs://placeholder" # example: gs://<temp-bucket>/splunk-forwarder-temp
  splunk_template_path           = local.splunk_forwarder_enabled ? "gs://dataflow-templates/latest/Cloud_PubSub_to_Splunk" : ""
  splunk_forwarder_job_name      = local.splunk_forwarder_enabled ? format("%s-probe-logs-splunk%s", local.env, var.splunk_enable_streaming_engine ? "-se" : "") : ""
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

  name        = "probe-to-bq"
  destination = "bigquery.googleapis.com/projects/${var.project_id}/datasets/${var.bq_dataset_id}"
  filter      = "jsonPayload.source=\"gcp.payment-probe\" AND jsonPayload.schema_version=\"v1\""

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
  filter      = "jsonPayload.source=\"gcp.payment-probe\" AND jsonPayload.schema_version=\"v1\""
}

# Grant sink writer identity permission to publish to the topic
resource "google_pubsub_topic_iam_member" "sink_publisher" {
  count = var.enable_pubsub_sink ? 1 : 0

  topic  = google_pubsub_topic.probe_logs.name
  role   = "roles/pubsub.publisher"
  member = google_logging_project_sink.probe_to_pubsub[0].writer_identity
}

# Splunk forwarder pipeline (feature-flagged)
resource "google_pubsub_subscription" "splunk" {
  count = local.splunk_forwarder_enabled ? 1 : 0

  name  = var.pubsub_subscription_name
  topic = google_pubsub_topic.probe_logs.name

  ack_deadline_seconds       = 30
  retain_acked_messages      = true
  message_retention_duration = "604800s" # 7 days

  labels = {
    env    = local.env
    target = "splunk-forwarder"
  }

  expiration_policy {
    ttl = "" # Never expire
  }
}

resource "google_compute_network" "splunk_dataflow" {
  count = local.splunk_forwarder_enabled ? 1 : 0

  name                    = "${local.env}-splunk-dataflow"
  project                 = var.project_id
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "splunk_dataflow" {
  count = local.splunk_forwarder_enabled ? 1 : 0

  name          = "${local.env}-splunk-dataflow-${local.dataflow_region}"
  project       = var.project_id
  region        = local.dataflow_region
  network       = google_compute_network.splunk_dataflow[count.index].id
  ip_cidr_range = "10.60.0.0/24"
}

resource "google_compute_subnetwork_iam_member" "splunk_worker_network_user" {
  count = local.splunk_forwarder_enabled ? 1 : 0

  project    = var.project_id
  region     = local.dataflow_region
  subnetwork = google_compute_subnetwork.splunk_dataflow[count.index].name
  role       = "roles/compute.networkUser"
  member     = "serviceAccount:${google_service_account.dataflow_splunk[count.index].email}"
}

resource "google_compute_subnetwork_iam_member" "splunk_dataflow_service_network_user" {
  count = local.splunk_forwarder_enabled ? 1 : 0

  project    = var.project_id
  region     = local.dataflow_region
  subnetwork = google_compute_subnetwork.splunk_dataflow[count.index].name
  role       = "roles/compute.networkUser"
  member     = "serviceAccount:${local.dataflow_service_agent}"
}

resource "google_service_account" "dataflow_splunk" {
  count = local.splunk_forwarder_enabled ? 1 : 0

  project      = var.project_id
  account_id   = "${local.env}-splunk-forwarder"
  display_name = "${upper(local.env)} Splunk Forwarder"
}

resource "google_project_iam_member" "splunk_dataflow_worker" {
  count = local.splunk_forwarder_enabled ? 1 : 0

  project = var.project_id
  role    = "roles/dataflow.worker"
  member  = "serviceAccount:${google_service_account.dataflow_splunk[count.index].email}"
}

resource "google_project_iam_member" "splunk_dataflow_developer" {
  count = local.splunk_forwarder_enabled ? 1 : 0

  project = var.project_id
  role    = "roles/dataflow.developer"
  member  = "serviceAccount:${google_service_account.dataflow_splunk[count.index].email}"
}

resource "google_project_iam_member" "splunk_logging" {
  count = local.splunk_forwarder_enabled ? 1 : 0

  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.dataflow_splunk[count.index].email}"
}

resource "google_project_iam_member" "splunk_monitoring" {
  count = local.splunk_forwarder_enabled ? 1 : 0

  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.dataflow_splunk[count.index].email}"
}

resource "google_project_iam_member" "splunk_network_user" {
  count = local.splunk_forwarder_enabled ? 1 : 0

  project = var.project_id
  role    = "roles/compute.networkUser"
  member  = "serviceAccount:${google_service_account.dataflow_splunk[count.index].email}"
}

resource "google_service_account_iam_member" "splunk_worker_impersonation" {
  count = local.splunk_forwarder_enabled ? 1 : 0

  service_account_id = google_service_account.dataflow_splunk[count.index].name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${local.dataflow_service_agent}"
}

resource "google_storage_bucket_iam_member" "splunk_dataflow_staging" {
  count = local.splunk_forwarder_enabled ? 1 : 0

  bucket = local.splunk_forwarder_enabled ? var.dataflow_staging_bucket : "placeholder"
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.dataflow_splunk[count.index].email}"
}

resource "google_pubsub_subscription_iam_member" "splunk_subscriber" {
  count = local.splunk_forwarder_enabled ? 1 : 0

  subscription = google_pubsub_subscription.splunk[count.index].name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${google_service_account.dataflow_splunk[count.index].email}"
}

resource "google_pubsub_subscription_iam_member" "splunk_dataflow_service_subscriber" {
  count = local.splunk_forwarder_enabled ? 1 : 0

  subscription = google_pubsub_subscription.splunk[count.index].name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${local.dataflow_service_agent}"
}

resource "google_pubsub_topic_iam_member" "splunk_dlq_publisher" {
  count = local.splunk_forwarder_enabled ? 1 : 0

  topic  = google_pubsub_topic.probe_logs_dlq.name
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${google_service_account.dataflow_splunk[count.index].email}"
}

resource "google_dataflow_job" "splunk" {
  count = local.splunk_forwarder_enabled ? 1 : 0

  name                  = local.splunk_forwarder_job_name
  project               = var.project_id
  region                = local.dataflow_region
  template_gcs_path     = local.splunk_template_path
  temp_gcs_location     = local.splunk_forwarder_temp_location
  max_workers           = var.splunk_max_workers
  machine_type          = var.splunk_machine_type
  service_account_email = local.splunk_forwarder_enabled ? google_service_account.dataflow_splunk[0].email : ""
  network               = google_compute_network.splunk_dataflow[0].name
  subnetwork            = google_compute_subnetwork.splunk_dataflow[0].self_link
  enable_streaming_engine = var.splunk_enable_streaming_engine
  on_delete             = "cancel"

  parameters = merge(
    {
      inputSubscription            = local.splunk_forwarder_enabled ? google_pubsub_subscription.splunk[0].id : ""
      url                          = var.splunk_hec_url
      token                        = var.splunk_hec_token
      batchCount                   = tostring(var.splunk_batch_count)
      disableCertificateValidation = tostring(var.splunk_hec_insecure_ssl)
      outputDeadletterTopic        = google_pubsub_topic.probe_logs_dlq.id
    },
    var.splunk_root_ca_gcs_path == null ? {} : { rootCaCertificatePath = var.splunk_root_ca_gcs_path }
  )

  lifecycle {
    precondition {
      condition     = var.splunk_hec_url != null && var.splunk_hec_token != null && var.dataflow_staging_bucket != null
      error_message = "enable_splunk_forwarder requires splunk_hec_url, splunk_hec_token, and dataflow_staging_bucket to be set."
    }
  }

  labels = {
    env    = local.env
    target = "splunk-forwarder"
  }

  depends_on = [
    google_service_account.dataflow_splunk,
    google_pubsub_subscription_iam_member.splunk_subscriber,
    google_pubsub_subscription_iam_member.splunk_dataflow_service_subscriber,
    google_project_iam_member.splunk_dataflow_worker,
    google_project_iam_member.splunk_dataflow_developer,
    google_project_iam_member.splunk_network_user,
    google_project_iam_member.splunk_logging,
    google_project_iam_member.splunk_monitoring,
    google_service_account_iam_member.splunk_worker_impersonation,
    google_storage_bucket_iam_member.splunk_dataflow_staging,
    google_pubsub_topic_iam_member.splunk_dlq_publisher,
    google_compute_network.splunk_dataflow,
    google_compute_subnetwork.splunk_dataflow,
    google_compute_subnetwork_iam_member.splunk_worker_network_user,
    google_compute_subnetwork_iam_member.splunk_dataflow_service_network_user,
    google_project_service.required,
  ]
}
