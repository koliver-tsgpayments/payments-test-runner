project_id      = "payments-test-runner-dev"
artifact_bucket = "code-releases-payments-dev"

functions = {
  tsgpayments = {
    artifact_object = "releases/tsg-v0.0.9-beta.zip"
    entry_point     = "run_tsgpayments"
    regions         = ["us-central1"]
    schedule        = "*/15 * * * *"
  }
  worldpay = {
    artifact_object = "releases/worldpay-v0.0.9-beta.zip"
    entry_point     = "run_worldpay"
    regions         = ["us-west4"]
    schedule        = "*/15 * * * *"
  }
}

enable_splunk_forwarder = true
splunk_hec_url          = "https://prd-p-3wvvs.splunkcloud.com:8088"
splunk_hec_token        = "92a743fc-339d-4c0b-ac3d-c89bb55a08c7"
splunk_index            = "payments"
