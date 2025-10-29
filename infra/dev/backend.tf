terraform {
  backend "gcs" {
    bucket = "tfstate-payments-test-runner-dev" # created via infra/bootstrap
    prefix = "terraform/dev"
  }
}
