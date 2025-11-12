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
- Structured probe envelope logs with stable fields (Splunk‑friendly).

> Note on regions: as of Oct 29, 2025, GCP has **no GA Mexico region**. Closest LATAM regions are São Paulo (`southamerica-east1`) and Santiago (`southamerica-west1`).

---

## 0) Local prerequisites
- Terraform >= 1.6
- gcloud CLI
- Python 3.12 (Cloud Functions runtime; install locally only if you want to build/test yourself)
- pytest (optional; run unit tests locally the same way CI does)

## 1) Local testing
- Start the lightweight HTTP shim (returns the structured envelope JSON and also emits it to logs):
  ```
  pip install -r functions/requirements.txt
  python -m functions.local_server
  ```
  The server listens on `http://0.0.0.0:8080` by default (override with `LOCAL_SERVER_PORT`).
  The HTTP response is the structured envelope; it’s also printed to the console.
  Hit it with curl or Postman:
  ```
  curl -X POST http://localhost:8080/tsg | jq
  curl -X POST http://localhost:8080/worldpay | jq
  ```
  Example response/log line (envelope):
  ```
  {"time":1730400000,"host":"local","source":"gcp.payment-probe","sourcetype":"payment_probe","event":{"schema_version":"v1","event_id":"...","function":"run_tsgpayments","region":"local","target":"tsgpayments","status":"OK","http_status":200,"latency_ms":123,"tenant":"default","severity":"INFO","extra":{}}}
  ```
- Want to exercise the deployed functions instead? Publish a Pub/Sub message and tail the logs:
  ```
  PROJECT=payments-test-runner-dev
  gcloud pubsub topics publish tsgpayments-topic-us-central1 --message='{"action":"run"}' --project="$PROJECT"
  gcloud logging read \
    'resource.type="cloud_run_revision" AND resource.labels.service_name="tsgpayments-us-central1" AND jsonPayload.source="gcp.payment-probe" AND jsonPayload.event.target="tsgpayments"' \
    --project="$PROJECT" \
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

# Optional logging/export toggles (defaults shown)
# enable_pubsub_sink       = false         # Cloud Logging → Pub/Sub export
# pubsub_topic_name        = "probe-logs"  # Topic for probe envelopes
# pubsub_dlq_topic_name    = "probe-logs-dlq" # DLQ topic for future consumers
# enable_bq_sink           = true          # BigQuery export (Log Router → BQ)

# Optional ops alerts toggles (defaults shown)
# enable_ops_alerts                = false
# monitoring_notification_channels = ["projects/$PROJECT/notificationChannels/<ID>"]
# probe_error_threshold            = 5
# probe_error_window_sec           = 300
# enable_pubsub_backlog_alert      = false
# pubsub_alert_subscription_name   = "probe-logs-splunk"   # when Dataflow is added
# pubsub_backlog_window_sec        = 600

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
PROJECT=payments-test-runner-dev
gcloud logging read \
  'resource.type="cloud_run_revision" AND resource.labels.service_name="tsgpayments-us-central1" AND jsonPayload.source="gcp.payment-probe" AND jsonPayload.event.target="tsgpayments"' \
  --project="$PROJECT" \
  --limit=20 \
--format=json
```

### Realtime export to Pub/Sub (Log Router)

This repo supports exporting probe envelopes from Cloud Logging to Pub/Sub via a Log Router sink. Flow:

```
Cloud Logging → Log Router Sink → Pub/Sub Topic → Subscription(s) → Subscriber(s)
```

- The sink is the publisher to Pub/Sub. It does not create subscriptions.
- Defaults in `infra/dev` and `infra/prod`:
  - `enable_pubsub_sink = false` → sink disabled (no publish to Pub/Sub)
  - `enable_bq_sink = true` → BigQuery export remains on by default
  - Topics are created by default and are harmless without subscriptions.

Variables you can toggle in `infra/*/variables.tf` and `.tfvars`:
- `enable_pubsub_sink` (bool): turn on/off the Logging → Pub/Sub export
- `pubsub_topic_name` (string): topic name for probe logs (default `probe-logs`)

#### Test with a temporary subscription

1) Enable the sink in dev and apply:
```
cd infra/dev
# in infra/dev/variables.tfvars set: enable_pubsub_sink = true
terraform init
terraform apply -var-file=variables.tfvars
```

2) Create a temporary subscription that auto-expires (24h):
```
PROJECT=payments-test-runner-dev
gcloud pubsub subscriptions create probe-logs-tmp \
  --topic=probe-logs \
  --expiration-period=24h \
  --project="$PROJECT"
```

3) Trigger a probe run to generate logs (which the sink publishes to Pub/Sub):
```
gcloud pubsub topics publish tsgpayments-topic-us-central1 \
  --message='{"action":"run"}' \
  --project="$PROJECT"
```

4) Pull a few messages:
```
gcloud pubsub subscriptions pull --auto-ack probe-logs-tmp \
  --project="$PROJECT" \
  --limit=5
```

Quick realtime pull (rerun to see new messages):
```
gcloud pubsub subscriptions pull probe-logs-tmp --auto-ack
```

5) Cleanup:
- If you didn’t set `--expiration-period`, delete the temp sub:
  ```
  gcloud pubsub subscriptions delete probe-logs-tmp --project="$PROJECT"
  ```
- Optionally disable the sink:
  - In `infra/dev/variables.tfvars`, set `enable_pubsub_sink = false`
  - Apply again: `terraform apply -var-file=variables.tfvars`
  - If you also want to delete the topics, you can target-destroy them:
    ```
    terraform destroy -var-file=variables.tfvars \
      -target=google_pubsub_topic.probe_logs \
      -target=google_pubsub_topic.probe_logs_dlq
    ```

Notes:
- Subscriptions only receive messages published after they are created.
- The sink filter is strict: `jsonPayload.source="gcp.payment-probe" AND jsonPayload.event.schema_version="v1"`.

### Streaming to Splunk (Dataflow Template)

Recommended production path to Splunk uses the Google‑provided Dataflow template. High‑level flow:

```
Cloud Logging → Log Router Sink → Pub/Sub Topic → Subscription → Dataflow (Pub/Sub → Splunk) → Splunk HEC
```

Why this path
- Auto‑scales for bursts; Pub/Sub buffers; Dataflow handles backoff/retries.
- DLQ patterns supported via a dead‑letter topic for failed HEC deliveries.
- Minimal Splunk footprint; send JSON envelopes directly to HEC.

What you’ll provision (later, via Terraform)
- A dedicated subscription on `probe-logs` for Dataflow (e.g., `probe-logs-splunk`).
- A Dataflow streaming job using the “Cloud Pub/Sub to Splunk” template.
- A worker service account with required roles: `pubsub.subscriber` on the sub, `dataflow.worker`, `storage.objectAdmin` on a staging bucket; `compute.networkUser` if using VPC/NAT.
- Optional: a DLQ topic (you can reuse `probe-logs-dlq`).

Inputs the template needs
- Splunk HEC URL (https) and HEC token.
- Batch size/bytes/interval, max workers, optional gzip.
- Optional: index, source, sourcetype overrides.

Terraform knobs (per env `variables.tfvars`)
- `enable_pubsub_sink` — turn on the Log Router → Pub/Sub export (creates the topic publisher).
- `enable_splunk_forwarder` — creates the subscription, service account, IAM, VPC, and runs the Dataflow template.
- `splunk_hec_url` / `splunk_hec_token` — required template parameters (URL must match the HEC certificate FQDN, no trailing slash).
- `dataflow_staging_bucket` — temp/staging bucket for Dataflow artifacts.
- `splunk_hec_insecure_ssl` (dev only) or `splunk_root_ca_gcs_path` — control TLS validation vs. providing a custom PEM chain.
- `splunk_index`, `splunk_source`, `splunk_sourcetype` — optional overrides applied per event.
- `splunk_batch_count`, `splunk_batch_bytes`, `splunk_batch_interval_sec` — batching controls; defaults are template-friendly.
- `splunk_max_workers`, `splunk_machine_type`, `dataflow_region` — govern scaling and placement.
- `splunk_enable_streaming_engine` — toggles Dataflow Streaming Engine (adds a `-se` suffix to the job name to force recreation).
- `pubsub_subscription_name`, `pubsub_dlq_topic_name` — dedicated subscription/DLQ names for the forwarder.

Planned next step
- See docs/prompt-splunk-dataflow.md for an AI‑ready prompt to wire this with Terraform. We’ll keep it toggleable (disabled by default) and parameterized per environment.

---

## 5) Terraform: PROD
Create `infra/prod/variables.tfvars`:
```hcl
project_id      = "payments-test-runner-prod"
artifact_bucket = "code-releases-payments-dev" # reading from DEV bucket

# Optional logging/export toggles (defaults shown)
# enable_pubsub_sink       = false         # Cloud Logging → Pub/Sub export
# pubsub_topic_name        = "probe-logs"  # Topic for probe envelopes
# pubsub_dlq_topic_name    = "probe-logs-dlq" # DLQ topic for future consumers
# enable_bq_sink           = true          # BigQuery export (Log Router → BQ)

# Optional ops alerts toggles (defaults shown)
# enable_ops_alerts                = false
# monitoring_notification_channels = ["projects/$PROJECT/notificationChannels/<ID>"]
# probe_error_threshold            = 5
# probe_error_window_sec           = 300
# enable_pubsub_backlog_alert      = false
# pubsub_alert_subscription_name   = "probe-logs-splunk"   # when Dataflow is added
# pubsub_backlog_window_sec        = 600

functions = {
  tsgpayments = {
    artifact_object = "releases/tsg-v1.0.0.zip"
    entry_point     = "run_tsgpayments"
    regions         = ["us-central1", "southamerica-east1"]
    schedule        = "*/10 * * * *"
  }
  worldpay = {
    artifact_object = "releases/worldpay-v1.0.0.zip"
    entry_point     = "run_worldpay"
    regions         = ["us-central1", "us-east4"]
    schedule        = "*/10 * * * *"
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
- Logs use a structured envelope (via Google Cloud StructuredLogHandler when available),
  making them easy to filter in Cloud Logging and ready for Splunk ingestion.

---

## BigQuery Export (Log Router)

Export only probe envelopes to BigQuery via the project-level Log Router.

- Defaults: `bq_dataset_id=payment_probe`, `bq_location=US`, `enable_bq_sink=true`, `bq_table_expiration_days=null`, `bq_sink_use_partitioned_tables=true`.
- Filter: `jsonPayload.source="gcp.payment-probe" AND jsonPayload.event.schema_version="v1"`.
- Toggle: set `enable_bq_sink` in `infra/*/variables.tfvars` (dataset remains if disabled).
- Note: Most envelopes land in `run_googleapis_com_stderr` (structured logging writes to stderr).
- More details: see `docs/prompt-bq-sink.md`.

Plan/apply (dev example)
```
cd infra/dev
terraform init
terraform plan -var-file=variables.tfvars
terraform apply -var-file=variables.tfvars
```

Trigger and verify
```
PROJECT=payments-test-runner-dev
gcloud pubsub topics publish tsgpayments-topic-us-central1 --message='{"action":"run"}' --project="$PROJECT"
gcloud logging sinks list --project="$PROJECT"
bq ls --project_id "$PROJECT" ${PROJECT}:$(terraform output -raw bq_dataset_id 2>/dev/null || echo payment_probe)
# Head the partitioned stderr table (most common)
bq head --project_id "$PROJECT" -n 5 payment_probe.run_googleapis_com_stderr
```

Query examples (partitioned tables)
```
# Last 20 envelopes (stderr), newest first
bq query --use_legacy_sql=false --project_id="$PROJECT" '
  SELECT
    timestamp,
    jsonPayload.event.target AS target,
    jsonPayload.event.status AS status,
    jsonPayload.event.http_status AS http_status,
    jsonPayload.event.latency_ms AS latency_ms,
    jsonPayload.region AS region
  FROM `payment_probe.run_googleapis_com_stderr`
  WHERE _PARTITIONTIME >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 DAY)
    AND jsonPayload.source = "gcp.payment-probe"
  ORDER BY timestamp DESC
  LIMIT 20'

# Count last hour (stderr)
bq query --use_legacy_sql=false --project_id="$PROJECT" '
  SELECT COUNT(1)
  FROM `payment_probe.run_googleapis_com_stderr`
  WHERE _PARTITIONTIME >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 DAY)
    AND timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 HOUR)
    AND jsonPayload.source = "gcp.payment-probe"'

# Across both streams (if stdout also exists)
bq query --use_legacy_sql=false --project_id="$PROJECT" '
  WITH logs AS (
    SELECT timestamp, jsonPayload FROM `payment_probe.run_googleapis_com_stderr`
    WHERE _PARTITIONTIME >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 DAY)
    UNION ALL
    SELECT timestamp, jsonPayload FROM `payment_probe.run_googleapis_com_stdout`
    WHERE _PARTITIONTIME >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 DAY)
  )
  SELECT COUNT(1)
  FROM logs
  WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 HOUR)
    AND jsonPayload.source = "gcp.payment-probe"'
```

If partitioning is disabled (daily-sharded tables)
```
# Count last day across shards
bq query --use_legacy_sql=false --project_id="$PROJECT" '
  SELECT COUNT(1)
  FROM `payment_probe.run_googleapis_com_stderr_*`
  WHERE _TABLE_SUFFIX >= FORMAT_DATE("%Y%m%d", DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY))
    AND jsonPayload.source = "gcp.payment-probe"'
```

Reusing an existing dataset
```
terraform import google_bigquery_dataset.probe projects/$PROJECT/datasets/$DATASET_ID
```


## Viewing Logs (Cloud Logging + Splunk)

All processors emit exactly one structured JSON envelope per invocation to a dedicated
log stream (default name `payment-probe`). The envelope shape is Splunk‑HEC compatible:

```
{
  "time": 1730400000,
  "host": "us-central1",
  "source": "gcp.payment-probe",
  "sourcetype": "payment_probe",
  "event": {
    "schema_version": "v1",
    "event_id": "b4b0c3c4-6c1c-4f0e-9a2e-6b2a7f9b1d90",
    "function": "run_tsgpayments",
    "region": "us-central1",
    "target": "tsgpayments",
    "status": "OK",
    "http_status": 200,
    "latency_ms": 123,
    "tenant": "default",
    "severity": "INFO",
    "extra": {}
  }
}
```

Key fields you can filter on:
- `labels."python_logger"="payment-probe"` (set by `LOG_NAME`; entries land under `run.googleapis.com/stderr`)
- `jsonPayload.source="gcp.payment-probe"`
- `jsonPayload.sourcetype="payment_probe"`
- `jsonPayload.event.target` (e.g., `tsgpayments`, `worldpay`)
- `jsonPayload.event.status` (`OK` or `ERROR`)
- `severity` (`INFO`, `WARNING`, `ERROR`)

### Logs Explorer (UI) examples
- All probe logs (simplest): `jsonPayload.source="gcp.payment-probe"`
- Only errors: `jsonPayload.source="gcp.payment-probe" severity=ERROR`
- Per target: `jsonPayload.source="gcp.payment-probe" jsonPayload.event.target="worldpay"`
- Per function: `jsonPayload.source="gcp.payment-probe" jsonPayload.event.function="run_tsgpayments"`
- By tenant: `jsonPayload.source="gcp.payment-probe" jsonPayload.event.tenant="default"`

### gcloud examples
```
PROJECT=payments-test-runner-dev
# Simplest: all probe envelopes
gcloud logging read 'jsonPayload.source="gcp.payment-probe"' --project="$PROJECT" --limit=50 --format=json

# Narrow by target
gcloud logging read 'jsonPayload.source="gcp.payment-probe" AND jsonPayload.event.target="tsgpayments"' --project="$PROJECT" --limit=50 --format=json

# Narrow by function entry point (e.g., run_tsgpayments)
gcloud logging read 'jsonPayload.source="gcp.payment-probe" AND jsonPayload.event.function="run_tsgpayments"' --project="$PROJECT" --limit=50 --format=json

# Only errors (two options)
gcloud logging read 'jsonPayload.source="gcp.payment-probe" AND severity=ERROR' --project="$PROJECT" --limit=50 --format=json
gcloud logging read 'jsonPayload.source="gcp.payment-probe" AND jsonPayload.event.status="ERROR"' --project="$PROJECT" --limit=50 --format=json

# Time range filters
# Last 1 hour
gcloud logging read 'jsonPayload.source="gcp.payment-probe"' --project="$PROJECT" --freshness=1h --format=json

# Specific window (RFC3339/ISO8601 UTC)
gcloud logging read 'jsonPayload.source="gcp.payment-probe" AND timestamp>="2025-10-31T00:00:00Z" AND timestamp<="2025-10-31T23:59:59Z"' \
  --project="$PROJECT" --format=json
```

Note: `event.target` is the logical processor alias (e.g., `tsgpayments`, `worldpay`) and stays stable across regions. `event.function` reflects the function entry point name in the runtime. Use either for scoping; `target` is generally simpler.

### Splunk notes
- The envelope matches Splunk HEC’s expected shape (`time`, `host`, `source`, `sourcetype`, `event`).
- Depending on how Splunk parsed the payload, fields might exist at both `event.*` and `jsonPayload.event.*`. The following pattern runs a single `| spath` and then uses `coalesce()` to grab whichever copy is present.
- Recommended Splunk search examples:
  - Latest payment probe (dev → `tsgpayments`, last 24h):
    ```
    index=payments earliest=-24h latest=now
    | spath
    | eval event_id=coalesce('event.event_id','jsonPayload.event.event_id')
    | eval target=coalesce('event.target','jsonPayload.event.target')
    | eval status=coalesce('event.status','jsonPayload.event.status')
    | eval latency_ms=coalesce('event.latency_ms','jsonPayload.event.latency_ms')
    | eval http_status=coalesce('event.http_status','jsonPayload.event.http_status')
    | search labels.env="dev" target="tsgpayments"
    | table _time event_id target status http_status latency_ms
    | sort - _time
    ```
  - Errors grouped by processor:
    ```
    index=payments earliest=-24h latest=now
    | spath
    | eval target=coalesce('event.target','jsonPayload.event.target')
    | eval status=coalesce('event.status','jsonPayload.event.status')
    | eval event_id=coalesce('event.event_id','jsonPayload.event.event_id')
    | search status="ERROR"
    | stats count AS errors latest(event_id) AS last_event by target
    | sort - errors
    ```
  - Latency health check (p95 > 2s):
    ```
    index=payments earliest=-24h latest=now
    | spath
    | eval target=coalesce('event.target','jsonPayload.event.target')
    | eval latency_ms=coalesce('event.latency_ms','jsonPayload.event.latency_ms')
    | stats perc95(latency_ms) AS p95 avg(latency_ms) AS avg by target
    | where p95 > 2000
    ```
- Routing to Splunk (sink/wiring) is out of scope here; use a Logging sink + Pub/Sub + Splunk HEC (or Splunk GCP add‑on). No transformation is needed—forward the envelope as‑is.
- Terraform stays module-free but relies on small `for_each` loops so you can manage processors in a single map.
