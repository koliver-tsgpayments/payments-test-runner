project_id      = "payments-test-runner-dev"
artifact_bucket = "code-releases-payments-dev"

functions = {
  tsgpayments = {
    artifact_object = "releases/tsg-v0.0.3-beta.zip"
    entry_point     = "run_tsgpayments"
    regions         = ["us-central1"]
    schedule        = "*/15 * * * *"
  }
  worldpay = {
    artifact_object = "releases/worldpay-v0.0.3-beta.zip"
    entry_point     = "run_worldpay"
    regions         = ["us-central1"]
    schedule        = "*/15 * * * *"
  }
}