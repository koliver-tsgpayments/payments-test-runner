# Payment Test Runner (GCP Cloud Functions + Terraform)

Small, explicit demo: Python Cloud Functions scheduled by Cloud Scheduler via Pub/Sub. 
Artifacts are built by GitHub CI on tag and exposed as downloadable workflow artifacts; you upload them to a **dev project** GCS bucket. Terraform is run locally; state lives in GCS for dev and prod.

## What you get
- Two processors:
  - `tsgpayments` → GET https://tsgpayments.com/ (dev: 15m, prod: 5m)
  - `worldpay` → GET https://worldpay.com/en (dev: 15m, prod: 5m)
- **Dev**: one region (`us-central1` by default)
- **Prod**: three regions (`us-central1`, `us-east4`, `southamerica-east1`). 
  - A commented South America region for `worldpay` shows how to add/remove regions.
- Structured JSON logs with `env`, `region`, `latency_ms`, `status_code`, `ok`, `error`.

> Note on regions: as of Oct 29, 2025, GCP has **no GA Mexico region**. Closest LATAM regions are São Paulo (`southamerica-east1`) and Santiago (`southamerica-west1`).

---

## 0) Local prerequisites
- Terraform >= 1.6
- gcloud CLI
- Python 3.12 (Cloud Functions runtime; install locally only if you want to build/test yourself)
- pytest (optional; run unit tests locally the same way CI does)

## 1) Local testing
- Start the lightweight HTTP shim (returns the same JSON payload logged in Cloud Functions):
  ```
  pip install -r functions/requirements.txt
  python -m functions.local_server
  ```
  The server listens on `http://0.0.0.0:8080` by default (override with `LOCAL_SERVER_PORT`). Hit it with curl or Postman:
  ```
  curl -X POST http://localhost:8080/tsg | jq
  curl -X POST http://localhost:8080/worldpay | jq
  ```
- Want to exercise the deployed functions instead? Publish a Pub/Sub message and tail the logs:
  ```
  gcloud pubsub topics publish tsgpayments-topic-us-central1 --message='{"action":"run"}' --project=payments-test-runner-dev
  gcloud logging read \
    'resource.type="cloud_run_revision" AND resource.labels.service_name="tsgpayments-us-central1" AND jsonPayload.processor="tsgpayments"' \
    --project=payments-test-runner-dev \
    --limit=5 \
    --format=json
  ```
- Run unit tests locally (mirrors CI):
  ```
  python -m pip install --upgrade pip
  pip install -r functions/requirements.txt pytest
  PYTHONPATH=. pytest
  ```

## 2) Bootstrap with Terraform (once)
Run the bootstrap stack to enable APIs, create Terraform state buckets, provision the shared release bucket, and configure Workload Identity Federation for GitHub Actions.

**Make sure you already have two GCP projects ready** (for example `payments-test-runner-dev` and `payments-test-runner-prod`). Terraform does not create projects, and billing must be enabled on each project so the required APIs can be turned on.

Create `infra/bootstrap/terraform.tfvars`:
```hcl
dev_project_id  = "payments-test-runner-dev"
prod_project_id = "payments-test-runner-prod"
github_repository = "your-org/your-repo" # owner/repo for GitHub Actions OIDC
# Optional overrides:
# release_bucket_name      = "code-releases-payments-dev"
# state_bucket_location    = "us-central1"
# release_bucket_location  = "us-central1"
# dev_state_bucket_name    = "tfstate-payments-test-runner-dev"
# prod_state_bucket_name   = "tfstate-payments-test-runner-prod"
```

Then run:
```
cd infra/bootstrap
terraform init
terraform apply -var-file=terraform.tfvars
```

Terraform will:
- Enable required APIs in dev and prod (`cloudfunctions`, `eventarc`, `run`, `pubsub`, `cloudscheduler`, `logging`, `cloudbuild`, `storage`).
- Create versioned Terraform state buckets (`tfstate-payments-test-runner-dev`, `tfstate-payments-test-runner-prod`) consumed by the dev/prod stacks.
- Create the release bucket (`code-releases-payments-dev`) in the dev project.
- Grant each project's Cloud Build service account `roles/storage.objectViewer` on the release bucket so Cloud Build can fetch artifacts.
- Create a GitHub-release service account with `roles/storage.objectCreator` on the release bucket.
- Configure a Workload Identity Pool + Provider restricted to your repository so GitHub Actions can impersonate the service account.

After the apply, grab the outputs and load them into GitHub secrets:
```
terraform output -raw release_bucket
terraform output -raw gcp_releaser_service_account
terraform output -raw gcp_workload_identity_provider
```

Set these secrets in your GitHub repo:
- `GCS_RELEASE_BUCKET_DEV` → value from `release_bucket`
- `GCP_RELEASER_SA_DEV` → value from `gcp_releaser_service_account`
- `GCP_WIF_PROVIDER_DEV` → value from `gcp_workload_identity_provider`

---

## 3) GitHub Flow: build & publish artifacts
CI builds on **tag** (e.g. `v1.0.0`), produces both function zips, and uploads them directly to the release bucket (`gs://code-releases-payments-dev/releases/`).

The workflow also publishes an artifact bundle you can download for reference:
```
dist/tsg-v1.0.0.zip
dist/worldpay-v1.0.0.zip
```

Push a tag to kick off the workflow:
```
git tag v1.0.0 && git push origin v1.0.0
```

When the workflow finishes you should see:
- Release bucket objects (`gs://code-releases-payments-dev/releases/tsg-v1.0.0.zip`, `worldpay-v1.0.0.zip`)
- Optional GitHub artifact download (`function-zips-v1.0.0`) if you want to inspect the zips locally

The workflow runs `pytest` before building artifacts to prevent broken processors from shipping.

---

## 4) Terraform: DEV
Edit `infra/dev/variables.tfvars` (create it) with:
```hcl
project_id      = "payments-test-runner-dev"
artifact_bucket = "code-releases-payments-dev"

functions = {
  tsgpayments = {
    artifact_object = "releases/tsg-v1.0.0.zip"
    entry_point     = "run_tsgpayments"
    regions         = ["us-central1"]
    schedule        = "*/15 * * * *"
  }
  worldpay = {
    artifact_object = "releases/worldpay-v1.0.0.zip"
    entry_point     = "run_worldpay"
    regions         = ["us-west4"]
    schedule        = "*/15 * * * *"
  }
}
```

Then:
```
cd infra/dev
terraform init
terraform plan -var-file=variables.tfvars
terraform apply -var-file=variables.tfvars
```

Each entry in `functions` spins up the supporting Pub/Sub topic(s), Cloud Functions, and Cloud Scheduler jobs for the listed regions. Adjust the cron expression per processor and add/remove regions as needed.

Check logs (example: latest `tsgpayments` run in dev):
```
gcloud logging read \
  'resource.type="cloud_run_revision" AND resource.labels.service_name="tsgpayments-us-central1" AND jsonPayload.processor="tsgpayments"' \
  --project=payments-test-runner-dev \
  --limit=20 \
  --format=json
```

---

## 5) Terraform: PROD
Create `infra/prod/variables.tfvars`:
```hcl
project_id      = "payments-test-runner-prod"
artifact_bucket = "code-releases-payments-dev" # reading from DEV bucket

functions = {
  tsgpayments = {
    artifact_object = "releases/tsg-v1.0.0.zip"
    entry_point     = "run_tsgpayments"
    regions         = ["us-central1", "us-east4", "southamerica-east1"]
    schedule        = "*/5 * * * *"
  }
  worldpay = {
    artifact_object = "releases/worldpay-v1.0.0.zip"
    entry_point     = "run_worldpay"
    regions         = ["us-central1", "us-east4"]
    schedule        = "*/5 * * * *"
  }
}
```

Then:
```
cd infra/prod
terraform init
terraform plan -var-file=variables.tfvars
terraform apply -var-file=variables.tfvars
```

You can promote new processors or regions by editing the map—no Terraform code changes required. Schedulers inherit the cron value defined per processor.

---

## 6) Promotion model
- CI always builds the artifact bundle for the tag and publishes it to the **dev bucket**.
- DEV stack pins whichever tag you want to test.
- PROD stack **promotes** by referencing the *same tag* (no rebuild). Rollback by pointing back to a prior tag.

---

## Notes
- We use **CF 2nd gen** + **Pub/Sub** triggers + **Cloud Scheduler** (no HTTP auth path).
- Cloud Functions run on Python 3.12; keep the runtime consistent when pinning dependencies or building artifacts locally.
- Logs are plain JSON strings for simplicity; BigQuery export works via Log Sinks later.
- Terraform stays module-free but relies on small `for_each` loops so you can manage processors in a single map.
