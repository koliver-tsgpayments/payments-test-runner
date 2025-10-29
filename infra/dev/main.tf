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
  region  = var.dev_region
}

# ---------- Pub/Sub topics ----------
resource "google_pubsub_topic" "tsg_topic" { name = "tsgpayments-topic" }
resource "google_pubsub_topic" "worldpay_topic" { name = "worldpay-topic" }

# ---------- Cloud Function: TSG (dev, single region) ----------
resource "google_cloudfunctions2_function" "tsg_dev" {
  name     = "tsgpayments-${var.dev_region}"
  location = var.dev_region
  labels   = { env = "dev", service = "test-runner", processor = "tsgpayments" }

  build_config {
    runtime     = "python312"
    entry_point = "run_tsgpayments"
    source {
      storage_source {
        bucket = var.artifact_bucket
        object = var.tsg_artifact_object
      }
    }
  }

  service_config {
    available_memory = "256M"
    timeout_seconds  = 60
    environment_variables = {
      ENV    = "dev"
      REGION = var.dev_region
    }
  }

  event_trigger {
    trigger_region = var.dev_region
    event_type     = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic   = google_pubsub_topic.tsg_topic.id
    retry_policy   = "RETRY_POLICY_RETRY"
  }
}

# ---------- Scheduler: TSG (every 15 minutes) ----------
resource "google_cloud_scheduler_job" "tsg_dev" {
  name      = "tsgpayments-cron-${var.dev_region}"
  schedule  = "*/15 * * * *"
  time_zone = "America/Denver"

  pubsub_target {
    topic_name = google_pubsub_topic.tsg_topic.id
    data       = base64encode(jsonencode({ action = "run", env = "dev" }))
  }
}

# ---------- Cloud Function: Worldpay (dev, single region) ----------
resource "google_cloudfunctions2_function" "worldpay_dev" {
  name     = "worldpay-${var.dev_region}"
  location = var.dev_region
  labels   = { env = "dev", service = "test-runner", processor = "worldpay" }

  build_config {
    runtime     = "python312"
    entry_point = "run_worldpay"
    source {
      storage_source {
        bucket = var.artifact_bucket
        object = var.worldpay_artifact_object
      }
    }
  }

  service_config {
    available_memory = "256M"
    timeout_seconds  = 60
    environment_variables = {
      ENV    = "dev"
      REGION = var.dev_region
    }
  }

  event_trigger {
    trigger_region = var.dev_region
    event_type     = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic   = google_pubsub_topic.worldpay_topic.id
    retry_policy   = "RETRY_POLICY_RETRY"
  }
}

# ---------- Scheduler: Worldpay (every 15 minutes) ----------
resource "google_cloud_scheduler_job" "worldpay_dev" {
  name      = "worldpay-cron-${var.dev_region}"
  schedule  = "*/15 * * * *"
  time_zone = "America/Denver"

  pubsub_target {
    topic_name = google_pubsub_topic.worldpay_topic.id
    data       = base64encode(jsonencode({ action = "run", env = "dev" }))
  }
}
