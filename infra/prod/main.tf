moved {
  from = google_logging_project_sink.probe_to_pubsub
  to   = module.stack.google_logging_project_sink.probe_to_pubsub
}
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

data "google_secret_manager_secret_version" "splunk_hec_token" {
  count   = var.splunk_hec_token_secret_name == null ? 0 : 1
  project = var.project_id
  secret  = var.splunk_hec_token_secret_name
  version = "latest"
}

locals {
  env                 = "prod"
  splunk_network_cidr = "10.60.1.0/24"
  splunk_hec_token_value = var.splunk_hec_token != null ? var.splunk_hec_token : (
    var.splunk_hec_token_secret_name == null ? null : data.google_secret_manager_secret_version.splunk_hec_token[0].secret_data
  )
}

module "stack" {
  source = "../modules/stack"

  environment         = local.env
  splunk_network_cidr = local.splunk_network_cidr

  project_id                     = var.project_id
  artifact_bucket                = var.artifact_bucket
  functions                      = var.functions
  scheduler_time_zone            = var.scheduler_time_zone
  bq_dataset_id                  = var.bq_dataset_id
  bq_location                    = var.bq_location
  enable_bq_sink                 = var.enable_bq_sink
  bq_table_expiration_days       = var.bq_table_expiration_days
  bq_sink_use_partitioned_tables = var.bq_sink_use_partitioned_tables
  enable_splunk_forwarder        = var.enable_splunk_forwarder
  dataflow_region                = var.dataflow_region
  pubsub_topic_name              = var.pubsub_topic_name
  pubsub_dlq_topic_name          = var.pubsub_dlq_topic_name
  pubsub_subscription_name       = var.pubsub_subscription_name
  splunk_hec_url                 = var.splunk_hec_url
  splunk_hec_token               = local.splunk_hec_token_value
  splunk_root_ca_gcs_path        = var.splunk_root_ca_gcs_path
  splunk_index                   = var.splunk_index
  splunk_source                  = var.splunk_source
  splunk_sourcetype              = var.splunk_sourcetype
  splunk_batch_count             = var.splunk_batch_count
  splunk_batch_bytes             = var.splunk_batch_bytes
  splunk_batch_interval_sec      = var.splunk_batch_interval_sec
  splunk_max_workers             = var.splunk_max_workers
  splunk_machine_type            = var.splunk_machine_type
}

moved {
  from = google_project_service.required
  to   = module.stack.google_project_service.required
}

moved {
  from = google_pubsub_topic.processor
  to   = module.stack.google_pubsub_topic.processor
}

moved {
  from = google_cloudfunctions2_function.processor
  to   = module.stack.google_cloudfunctions2_function.processor
}

moved {
  from = google_cloud_scheduler_job.processor
  to   = module.stack.google_cloud_scheduler_job.processor
}

moved {
  from = google_bigquery_dataset.probe
  to   = module.stack.google_bigquery_dataset.probe
}

moved {
  from = google_logging_project_sink.probe_to_bq
  to   = module.stack.google_logging_project_sink.probe_to_bq
}

moved {
  from = google_bigquery_dataset_iam_member.sink_writer
  to   = module.stack.google_bigquery_dataset_iam_member.sink_writer
}

moved {
  from = google_pubsub_topic.probe_logs
  to   = module.stack.google_pubsub_topic.probe_logs
}

moved {
  from = google_pubsub_topic.probe_logs_dlq
  to   = module.stack.google_pubsub_topic.probe_logs_dlq
}

moved {
  from = google_logging_project_sink.probe_to_pubsub
  to   = module.stack.google_logging_project_sink.probe_to_pubsub
}

moved {
  from = google_pubsub_topic_iam_member.sink_publisher
  to   = module.stack.google_pubsub_topic_iam_member.sink_publisher
}

moved {
  from = google_pubsub_subscription.splunk
  to   = module.stack.google_pubsub_subscription.splunk
}

moved {
  from = google_compute_network.splunk_dataflow
  to   = module.stack.google_compute_network.splunk_dataflow
}

moved {
  from = google_compute_subnetwork.splunk_dataflow
  to   = module.stack.google_compute_subnetwork.splunk_dataflow
}

moved {
  from = google_compute_subnetwork_iam_member.splunk_worker_network_user
  to   = module.stack.google_compute_subnetwork_iam_member.splunk_worker_network_user
}

moved {
  from = google_compute_subnetwork_iam_member.splunk_dataflow_service_network_user
  to   = module.stack.google_compute_subnetwork_iam_member.splunk_dataflow_service_network_user
}

moved {
  from = google_service_account.dataflow_splunk
  to   = module.stack.google_service_account.dataflow_splunk
}

moved {
  from = google_project_iam_member.splunk_dataflow_worker
  to   = module.stack.google_project_iam_member.splunk_dataflow_worker
}

moved {
  from = google_project_iam_member.splunk_dataflow_developer
  to   = module.stack.google_project_iam_member.splunk_dataflow_developer
}

moved {
  from = google_project_iam_member.splunk_logging
  to   = module.stack.google_project_iam_member.splunk_logging
}

moved {
  from = google_project_iam_member.splunk_monitoring
  to   = module.stack.google_project_iam_member.splunk_monitoring
}

moved {
  from = google_project_iam_member.splunk_network_user
  to   = module.stack.google_project_iam_member.splunk_network_user
}

moved {
  from = google_service_account_iam_member.splunk_worker_impersonation
  to   = module.stack.google_service_account_iam_member.splunk_worker_impersonation
}

moved {
  from = google_storage_bucket_iam_member.splunk_dataflow_staging
  to   = module.stack.google_storage_bucket_iam_member.splunk_dataflow_staging
}

moved {
  from = google_pubsub_subscription_iam_member.splunk_subscriber
  to   = module.stack.google_pubsub_subscription_iam_member.splunk_subscriber
}

moved {
  from = google_pubsub_subscription_iam_member.splunk_dataflow_service_subscriber
  to   = module.stack.google_pubsub_subscription_iam_member.splunk_dataflow_service_subscriber
}

moved {
  from = google_pubsub_topic_iam_member.splunk_dlq_publisher
  to   = module.stack.google_pubsub_topic_iam_member.splunk_dlq_publisher
}

moved {
  from = google_dataflow_job.splunk
  to   = module.stack.google_dataflow_job.splunk
}
