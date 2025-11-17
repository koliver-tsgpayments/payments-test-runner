# Payment Test Runner (GCP Cloud Functions + Terraform)

An opinionated reference for scheduling HTTP probes via Cloud Functions (Python 3.12) on GCP. GitHub Actions builds tagged function artifacts, Terraform deploys them to dev/prod, and structured logs flow to Cloud Logging, BigQuery, Pub/Sub, and Splunk-ready outputs.

## Overview
- Processors (`tsgpayments`, `worldpay`) run on cron-driven Cloud Functions (CF 2nd gen) via Scheduler → Pub/Sub triggers; each simply issues a public HTTP GET to the vendor site today so you can see the pattern end-to-end before swapping in real payment processors.
- Multi-region: dev targets one region, prod fans out to multiple (e.g., `us-central1`, `us-east4`, `southamerica-east1`).
- Infrastructure-as-code end to end: bootstrap, dev, and prod stacks share Terraform state in GCS buckets.
- Logging is a first-class feature: every invocation emits the same JSON envelope, ready for Cloud Logging filters, BigQuery queries, Pub/Sub subscribers, Splunk/Dataflow, and future third-party sinks.
- Promotion is artifact-driven: build once on a tag, promote by pointing Terraform at the desired zip.

---

## Architecture Overview
```
GitHub Tag → GitHub Actions → GCS release bucket
                                     │
                                     ▼
Cloud Scheduler → Pub/Sub (per processor) → Cloud Functions (Python) → Cloud Logging (structured logs)
                                                                     │
                                                                     ├─ Log Router sink → BigQuery dataset (partitioned)
                                                                     └─ Log Router sink → Pub/Sub topic (`probe-logs`)
                                                                                         └─ Subscribers (Dataflow → Splunk, future integrations)
```

### Flow
1. Developer pushes a tag (e.g., `v1.0.0`). GitHub Actions runs `pytest`, builds processor zips, and drops them in the dev release bucket (`gs://code-releases-payments-dev/releases/`).
2. Terraform (run locally) deploys Cloud Functions, Pub/Sub topics, and Cloud Scheduler jobs per environment using the artifact references.
3. Each invocation logs a structured probe envelope. The Log Router exports envelopes to BigQuery and Pub/Sub by default; Pub/Sub subscribers feed Splunk or any downstream analytics stack.

---

## Local Development & Testing
### Prerequisites
- Terraform ≥ 1.6
- `gcloud` CLI authenticated to the target projects
- Python 3.12 (matches the Cloud Functions runtime)
- `pip`, `pytest`, and `jq` (optional but handy for local inspection)

### Quickstart: run the shim locally
1. Install dependencies and start the lightweight HTTP server:
   ```bash
   pip install -r functions/requirements.txt
   python -m functions.local_server
   ```
2. Invoke processors locally:
   ```bash
   curl -X POST http://localhost:8080/tsg | jq
   curl -X POST http://localhost:8080/worldpay | jq
   ```
   The response and stdout both contain the structured envelope; override the port with `LOCAL_SERVER_PORT`.
3. Inspect the envelope (truncated):
   ```json
   {"schema_version":"v1","time":1730400000,"event_id":"...","function":"run_tsgpayments","region":"local","env":"local","target":"tsgpayments","status":"OK","http_status":200,"latency_ms":123,"tenant":"default","severity":"INFO","extra":{},"host":"local","source":"gcp.payment-probe","sourcetype":"payment_probe"}
   ```

### Talk to deployed processors
Publish to the deployed Pub/Sub topic and tail logs:
```bash
PROJECT=payments-test-runner-dev
 gcloud pubsub topics publish tsgpayments-topic-us-central1 --message='{"action":"run"}' --project="$PROJECT"
 gcloud logging read \
   'resource.type="cloud_run_revision" AND resource.labels.service_name="tsgpayments-us-central1" AND jsonPayload.source="gcp.payment-probe" AND jsonPayload.target="tsgpayments"' \
   --project="$PROJECT" \
   --limit=5 \
   --format=json
```

### Run the unit test suite (mirrors CI)
```bash
python -m pip install --upgrade pip
pip install -r functions/requirements.txt pytest
PYTHONPATH=. pytest
```

### Troubleshooting cheat sheet
| Symptom | Fix |
| --- | --- |
| Local server port already in use | `LOCAL_SERVER_PORT=9090 python -m functions.local_server` |
| Missing deps / mismatched runtime | Ensure Python 3.12 and rerun `pip install -r functions/requirements.txt` |
| Pub/Sub publish fails | Confirm `PROJECT` env matches the deployed stack and you have `pubsub.publisher` creds |
| Terraform init cannot find state bucket | Run the bootstrap stack first to create the GCS buckets |

---

## Adding a processor (new Cloud Function)
1. **Implement the processor** under `functions/` (e.g., `functions/processor_foo.py`). Use the existing probes as reference and emit the structured log envelope via the provided logging helper.
2. **Test locally:** add/extend pytest cases under `tests/`, run `PYTHONPATH=. pytest`, and invoke via the local server.
3. **Package via CI:** once merged, tag a version so GitHub Actions produces `releases/<processor>-<tag>.zip` in the dev release bucket. You can also build locally if required, but Terraform expects the artifact in GCS.
4. **Wire Terraform:** edit `infra/dev/variables.tfvars` (and later prod) to add an entry in the `functions` map:
   ```hcl
   functions = {
     foo = {
       artifact_object = "releases/foo-v1.2.3.zip"
       entry_point     = "run_foo"
       regions         = ["us-central1"]
       schedule        = "*/5 * * * *" # cron expression
     }
     # existing processors ...
   }
   ```
   Applying Terraform spins up the Pub/Sub topic(s), Cloud Functions, and Scheduler jobs automatically for each region.

---

## Release flow (GitHub Actions + artifacts)
- Pipelines trigger on git tags (`v*`). CI runs `pytest`, builds both processor zips, and uploads them to `gs://code-releases-payments-dev/releases/`.
- Workflow artifacts named `function-zips-<tag>.zip` remain downloadable from the GitHub UI for manual inspection.
- Promote a build by referencing the new artifact path in the `functions` map and re-running Terraform; no rebuild is required for prod.

---

## Infrastructure with Terraform
### Stack summary
| Stack | Purpose | State bucket | Key outputs |
| --- | --- | --- | --- |
| `infra/bootstrap` | One-time APIs, Terraform state buckets, release bucket, GitHub OIDC wiring | `tfstate-payments-test-runner-{dev,prod}` | Release bucket name, GitHub Workload Identity provider + service account |
| `infra/dev` | Dev Cloud Functions, Pub/Sub, Scheduler, log sinks | `tfstate-payments-test-runner-dev` | Function URLs (if HTTP), log sink IDs, BigQuery dataset/table ids |
| `infra/prod` | Production deployment (multi-region, shared artifact bucket) | `tfstate-payments-test-runner-prod` | Same as dev with prod project ids |

### Bootstrap once
1. Create two GCP projects (billing enabled), e.g., `payments-test-runner-dev` and `payments-test-runner-prod`.
2. Create `infra/bootstrap/terraform.tfvars`:
   ```hcl
   dev_project_id   = "payments-test-runner-dev"
   prod_project_id  = "payments-test-runner-prod"
   github_repository = "your-org/your-repo" # for GitHub Actions OIDC
   # Optional overrides for bucket names/locations
   ```
3. Apply:
   ```bash
   cd infra/bootstrap
   terraform init
   terraform apply -var-file=terraform.tfvars
   ```
4. Capture outputs and set GitHub secrets:
   ```bash
   terraform output -raw release_bucket
   terraform output -raw gcp_releaser_service_account
   terraform output -raw gcp_workload_identity_provider
   ```
   | GitHub secret | Value |
   | --- | --- |
   | `GCS_RELEASE_BUCKET_DEV` | `release_bucket` |
   | `GCP_RELEASER_SA_DEV` | `gcp_releaser_service_account` |
   | `GCP_WIF_PROVIDER_DEV` | `gcp_workload_identity_provider` |

### Deploy dev
`infra/dev/variables.tfvars` (create it):
```hcl
project_id      = "payments-test-runner-dev"
artifact_bucket = "code-releases-payments-dev"

# Logging/export knobs (defaults shown)
pubsub_topic_name     = "probe-logs"
pubsub_dlq_topic_name = "probe-logs-dlq"
enable_bq_sink        = true

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
Apply:
```bash
cd infra/dev
terraform init
terraform plan -var-file=variables.tfvars
terraform apply -var-file=variables.tfvars
```

### Deploy prod
`infra/prod/variables.tfvars` mirrors dev but references the prod project and preferred regions:
```hcl
project_id      = "payments-test-runner-prod"
artifact_bucket = "code-releases-payments-dev" # reuse dev release bucket

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
Apply with the same `terraform init/plan/apply` flow.

### Promotion model
- CI always uploads artifacts to the dev bucket.
- Dev stack pins whichever tag you wish to test.
- Prod stack promotes by pointing to the same artifact (no rebuild). Rollbacks are just pointer changes in `variables.tfvars`.

---

## Observability & Logging (first-class citizens)
Logs are emitted once per invocation using a stable schema so every downstream consumer can rely on identical fields.

### Structured envelope
```json
{
  "schema_version": "v1",
  "time": 1730400000,
  "event_id": "b4b0c3c4-6c1c-4f0e-9a2e-6b2a7f9b1d90",
  "function": "run_tsgpayments",
  "region": "us-central1",
  "env": "dev",
  "target": "tsgpayments",
  "status": "OK",
  "http_status": 200,
  "latency_ms": 123,
  "tenant": "default",
  "severity": "INFO",
  "extra": {},
  "host": "us-central1",
  "source": "gcp.payment-probe",
  "sourcetype": "payment_probe"
}
```
| Field | Type | Notes |
| --- | --- | --- |
| `schema_version` | STRING | Envelope schema id (`v1`) |
| `time` | INT64 | Unix epoch seconds when the log was emitted |
| `event_id` | STRING | UUID per invocation |
| `function` | STRING | Cloud Function entry point (e.g., `run_tsgpayments`) |
| `region` | STRING | Region or `local` when running locally |
| `env` | STRING | Deployment environment (`dev`, `prod`, `local`, …) |
| `target` | STRING | Logical processor alias |
| `status` | STRING | `OK` or `ERROR` |
| `http_status` | INT64 | Downstream HTTP status |
| `latency_ms` | INT64 | Total runtime latency |
| `tenant` | STRING | Defaults to `default`; extend for multi-tenancy |
| `severity` | STRING | Log severity emitted |
| `extra` | JSON | Free-form diagnostic info |
| `host` | STRING | Mirrors region/function for Splunk friendliness |
| `source` / `sourcetype` | STRING | Fixed values for Splunk HEC (`gcp.payment-probe`, `payment_probe`) |

### Default routing & sinks
| Sink | Default | Consumer | Toggle / Config |
| --- | --- | --- | --- |
| Cloud Logging (`run.googleapis.com/stderr`) | Always on | UI, `gcloud logging read` | n/a |
| BigQuery dataset `payment_probe` | Enabled (`enable_bq_sink=true`) | Ad-hoc SQL, dashboards | `bq_dataset_id`, `bq_location`, partition settings |
| Pub/Sub topic `probe-logs` | Enabled | Splunk/Dataflow, third-party subscribers | `pubsub_topic_name`, `pubsub_dlq_topic_name` |
| Dataflow Pub/Sub → Splunk | Disabled by default | Splunk HEC (logs + DLQ) | `enable_splunk_forwarder`, `splunk_*` vars |
| Future 3rd parties | Add subscriptions to `probe-logs` (Dataflow, Cloud Run, etc.) | Any JSON-friendly consumer | Manage outside Terraform or extend modules |

### Pub/Sub sink quick test
1. Apply the dev stack (ensures the Log Router sink publishes to Pub/Sub).
2. Create a temporary subscription (expires in 24h):
   ```bash
   PROJECT=payments-test-runner-dev
   gcloud pubsub subscriptions create probe-logs-tmp \
     --topic=probe-logs \
     --expiration-period=24h \
     --project="$PROJECT"
   ```
3. Trigger a run:
   ```bash
   gcloud pubsub topics publish tsgpayments-topic-us-central1 --message='{"action":"run"}' --project="$PROJECT"
   ```
4. Pull messages:
   ```bash
   gcloud pubsub subscriptions pull --auto-ack probe-logs-tmp --project="$PROJECT" --limit=5
   ```
5. Clean up if you skipped `--expiration-period`:
   ```bash
   gcloud pubsub subscriptions delete probe-logs-tmp --project="$PROJECT"
   ```

### Streaming to Splunk (Pub/Sub → Dataflow → HEC)
Recommended production path leverages the Google-managed Dataflow template:
```
Cloud Logging → Log Router → Pub/Sub (`probe-logs`) → Subscription (e.g., `probe-logs-splunk`) → Dataflow template → Splunk HEC
```
- Terraform knobs per environment: `enable_splunk_forwarder`, `splunk_hec_url`, `splunk_hec_token_secret_name` (preferred), batching controls, worker sizing, and optional TLS overrides.
- Provision a Secret Manager secret first:
  ```bash
  PROJECT=payments-test-runner-dev
  gcloud secrets create splunk-hec-token --project="$PROJECT" --replication-policy="automatic"
  printf 'YOUR-TOKEN-HERE' | gcloud secrets versions add splunk-hec-token --project="$PROJECT" --data-file=-
  ```
- Set `splunk_hec_token_secret_name = "splunk-hec-token"` in `variables.tfvars`; Terraform pulls the latest version at apply time.
- The Dataflow job reuses the release bucket for staging, runs with Streaming Engine enabled, and can be extended to forward logs to other third-party services by swapping the subscriber template (e.g., Pub/Sub → Cloud Run if Splunk is replaced later).

### BigQuery export
- Defaults: `bq_dataset_id=payment_probe`, `bq_location=US`, `bq_sink_use_partitioned_tables=true`.
- Query examples:
  ```bash
  PROJECT=payments-test-runner-dev
  bq query --use_legacy_sql=false --project_id="$PROJECT" '
    SELECT
      timestamp,
      jsonPayload.target AS target,
      jsonPayload.status AS status,
      jsonPayload.http_status AS http_status,
      jsonPayload.latency_ms AS latency_ms,
      jsonPayload.region AS region
    FROM `payment_probe.run_googleapis_com_stderr`
    WHERE _PARTITIONTIME >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 DAY)
      AND jsonPayload.source = "gcp.payment-probe"
    ORDER BY timestamp DESC
    LIMIT 20'
  ```
- Count the last hour across stderr/stdout:
  ```bash
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
- Reuse an existing dataset by importing it into Terraform: `terraform import google_bigquery_dataset.probe projects/$PROJECT/datasets/$DATASET_ID`.

### Querying logs
**Cloud Logging (UI or CLI)**
- All probe logs: `jsonPayload.source="gcp.payment-probe"`
- Errors only: add `severity=ERROR` or `jsonPayload.status="ERROR"`
- Per target: `jsonPayload.target="worldpay"`
- CLI example:
  ```bash
  PROJECT=payments-test-runner-dev
  gcloud logging read 'jsonPayload.source="gcp.payment-probe"' --project="$PROJECT" --limit=50 --format=json
  gcloud logging read 'jsonPayload.source="gcp.payment-probe" AND jsonPayload.target="tsgpayments"' --project="$PROJECT" --limit=50 --format=json
  gcloud logging read 'jsonPayload.source="gcp.payment-probe" AND timestamp>="2025-10-31T00:00:00Z" AND timestamp<="2025-10-31T23:59:59Z"' --project="$PROJECT" --format=json
  ```

**Pub/Sub subscribers**
- Use the topic `probe-logs`; messages contain the flattened envelope, so existing Dataflow, Splunk, or Cloud Run consumers can ingest without transforms.
- Dead-lettering defaults to `probe-logs-dlq`; add backlog or delivery alerts separately if your downstream system needs them.

**Splunk searches**
Run `| spath` once to normalize fields regardless of whether Splunk parsed them at the top level or under `jsonPayload.*`.
- Latest probe for a target:
  ```splunk
  index=payments earliest=-24h latest=now
  | spath
  | eval target=coalesce('target','jsonPayload.target')
  | eval status=coalesce('status','jsonPayload.status')
  | search target="tsgpayments" labels.env="dev"
  | table _time event_id target status http_status latency_ms
  | sort - _time
  ```
- Error summary:
  ```splunk
  index=payments earliest=-24h latest=now
  | spath
  | eval target=coalesce('target','jsonPayload.target')
  | eval status=coalesce('status','jsonPayload.status')
  | search status="ERROR"
  | stats count AS errors latest(event_id) AS last_event by target
  | sort - errors
  ```
- Latency health check:
  ```splunk
  index=payments earliest=-24h latest=now
  | spath
  | eval target=coalesce('target','jsonPayload.target')
  | eval latency_ms=coalesce('latency_ms','jsonPayload.latency_ms')
  | stats perc95(latency_ms) AS p95 avg(latency_ms) AS avg by target
  | where p95 > 2000
  ```

Because the envelope is standardized, the same searches work if logs land in Splunk via HEC, BigQuery via Log Router, or any third-party observability platform you connect through Pub/Sub.

---

## Notes
- Cloud Functions use Python 3.12; keep dependencies compatible and pin versions before tagging a release.
- Terraform keeps processors configurable via maps—no modules are required to add/remove processors or regions.
- As of Oct 29, 2025, there is no GA GCP Mexico region; use São Paulo (`southamerica-east1`) or Santiago (`southamerica-west1`) for Latin America coverage.
