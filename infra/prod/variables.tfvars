project_id      = "payments-test-runner-prod"
artifact_bucket = "code-releases-payments-dev" # reading from DEV bucket

functions = {
  tsgpayments = {
    artifact_object = "releases/tsg-v0.0.7-beta.zip"
    entry_point     = "run_tsgpayments"
    regions         = ["us-central1", "southamerica-east1"]
    schedule        = "*/10 * * * *"
  }
  worldpay = {
    artifact_object = "releases/worldpay-v0.0.7-beta.zip"
    entry_point     = "run_worldpay"
    regions         = ["us-central1", "us-east4"]
    schedule        = "*/10 * * * *"
  }
}