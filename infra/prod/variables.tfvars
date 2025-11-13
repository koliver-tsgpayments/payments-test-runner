project_id      = "payments-test-runner-prod"
artifact_bucket = "code-releases-payments-dev" # reading from DEV bucket

functions = {
  tsgpayments = {
    artifact_object = "releases/tsg-v0.0.9-beta.zip"
    entry_point     = "run_tsgpayments"
    regions         = ["us-central1", "southamerica-east1"]
    schedule        = "*/10 * * * *"
  }
  worldpay = {
    artifact_object = "releases/worldpay-v0.0.9-beta.zip"
    entry_point     = "run_worldpay"
    regions         = ["us-central1", "us-east4"]
    schedule        = "*/10 * * * *"
  }
}

enable_splunk_forwarder = false
splunk_hec_url          = "https://prd-p-3wvvs.splunkcloud.com:8088"
splunk_hec_token        = "92a743fc-339d-4c0b-ac3d-c89bb55a08c7"
splunk_index = "payments"
