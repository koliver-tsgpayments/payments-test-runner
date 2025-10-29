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
  region  = var.region_us1
}

# ---------- Pub/Sub topics per processor/region ----------
resource "google_pubsub_topic" "tsg_us1" { name = "tsgpayments-topic-${var.region_us1}" }
resource "google_pubsub_topic" "tsg_us2" { name = "tsgpayments-topic-${var.region_us2}" }
resource "google_pubsub_topic" "tsg_latam" { name = "tsgpayments-topic-${var.region_latam}" }

resource "google_pubsub_topic" "worldpay_us1" { name = "worldpay-topic-${var.region_us1}" }
resource "google_pubsub_topic" "worldpay_us2" { name = "worldpay-topic-${var.region_us2}" }
# South America region for demo (commented example for adding new regions)
# resource "google_pubsub_topic" "worldpay_latam" { name = "worldpay-topic-${var.region_latam}" }

# ---------- Cloud Function: TSG (prod, 3 regions) ----------
resource "google_cloudfunctions2_function" "tsg_us1" {
  name     = "tsgpayments-${var.region_us1}"
  location = var.region_us1
  labels   = { env = "prod", service = "test-runner", processor = "tsgpayments" }

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
      ENV    = "prod"
      REGION = var.region_us1
    }
  }
  event_trigger {
    trigger_region = var.region_us1
    event_type     = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic   = google_pubsub_topic.tsg_us1.id
    retry_policy   = "RETRY_POLICY_RETRY"
  }
}

resource "google_cloudfunctions2_function" "tsg_us2" {
  name     = "tsgpayments-${var.region_us2}"
  location = var.region_us2
  labels   = { env = "prod", service = "test-runner", processor = "tsgpayments" }

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
      ENV    = "prod"
      REGION = var.region_us2
    }
  }
  event_trigger {
    trigger_region = var.region_us2
    event_type     = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic   = google_pubsub_topic.tsg_us2.id
    retry_policy   = "RETRY_POLICY_RETRY"
  }
}

resource "google_cloudfunctions2_function" "tsg_latam" {
  name     = "tsgpayments-${var.region_latam}"
  location = var.region_latam
  labels   = { env = "prod", service = "test-runner", processor = "tsgpayments" }

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
      ENV    = "prod"
      REGION = var.region_latam
    }
  }
  event_trigger {
    trigger_region = var.region_latam
    event_type     = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic   = google_pubsub_topic.tsg_latam.id
    retry_policy   = "RETRY_POLICY_RETRY"
  }
}

# ---------- Schedulers: TSG (every 5 minutes) ----------
resource "google_cloud_scheduler_job" "tsg_us1" {
  name      = "tsgpayments-cron-${var.region_us1}"
  schedule  = "*/5 * * * *"
  time_zone = "America/Denver"
  pubsub_target {
    topic_name = google_pubsub_topic.tsg_us1.id
    data       = base64encode(jsonencode({ action = "run", env = "prod" }))
  }
}
resource "google_cloud_scheduler_job" "tsg_us2" {
  name      = "tsgpayments-cron-${var.region_us2}"
  schedule  = "*/5 * * * *"
  time_zone = "America/Denver"
  pubsub_target {
    topic_name = google_pubsub_topic.tsg_us2.id
    data       = base64encode(jsonencode({ action = "run", env = "prod" }))
  }
}
resource "google_cloud_scheduler_job" "tsg_latam" {
  name      = "tsgpayments-cron-${var.region_latam}"
  schedule  = "*/5 * * * *"
  time_zone = "America/Denver"
  pubsub_target {
    topic_name = google_pubsub_topic.tsg_latam.id
    data       = base64encode(jsonencode({ action = "run", env = "prod" }))
  }
}

# ---------- Cloud Function: Worldpay (prod, 2 US regions; LATAM commented example) ----------
resource "google_cloudfunctions2_function" "worldpay_us1" {
  name     = "worldpay-${var.region_us1}"
  location = var.region_us1
  labels   = { env = "prod", service = "test-runner", processor = "worldpay" }

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
      ENV    = "prod"
      REGION = var.region_us1
    }
  }
  event_trigger {
    trigger_region = var.region_us1
    event_type     = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic   = google_pubsub_topic.worldpay_us1.id
    retry_policy   = "RETRY_POLICY_RETRY"
  }
}

resource "google_cloudfunctions2_function" "worldpay_us2" {
  name     = "worldpay-${var.region_us2}"
  location = var.region_us2
  labels   = { env = "prod", service = "test-runner", processor = "worldpay" }

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
      ENV    = "prod"
      REGION = var.region_us2
    }
  }
  event_trigger {
    trigger_region = var.region_us2
    event_type     = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic   = google_pubsub_topic.worldpay_us2.id
    retry_policy   = "RETRY_POLICY_RETRY"
  }
}

# Example to add a South America region later (uncomment to demo extra region)
# resource "google_cloudfunctions2_function" "worldpay_latam" {
#   name     = "worldpay-${var.region_latam}"
#   location = var.region_latam
#   labels   = { env = "prod", service = "test-runner", processor = "worldpay" }
#   build_config {
#     runtime     = "python312"
#     entry_point = "run_worldpay"
#     source { storage_source { bucket = var.artifact_bucket, object = var.worldpay_artifact_object } }
#   }
#   service_config { available_memory = "256M", timeout_seconds = 60, environment_variables = { ENV="prod", REGION = var.region_latam } }
#   event_trigger { trigger_region = var.region_latam, event_type = "google.cloud.pubsub.topic.v1.messagePublished", pubsub_topic = google_pubsub_topic.worldpay_latam.id, retry_policy = "RETRY_POLICY_RETRY" }
# }
# resource "google_cloud_scheduler_job" "worldpay_latam" {
#   name = "worldpay-cron-${var.region_latam}"
#   schedule = "*/5 * * * *"
#   time_zone = "America/Denver"
#   pubsub_target { topic_name = google_pubsub_topic.worldpay_latam.id, data = base64encode(jsonencode({ action = "run", env = "prod" })) }
# }
