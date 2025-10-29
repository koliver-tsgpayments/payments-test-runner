terraform {
  backend "gcs" {
    bucket = "tfstate-payments-test-runner-prod" # created via infra/bootstrap
    prefix = "terraform/prod"
  }
}
