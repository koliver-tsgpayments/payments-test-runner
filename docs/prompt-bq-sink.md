# Prompt — BigQuery Export Sink (Terraform Only)

You are assisting on the payments probe project. The Python structured log envelope is already implemented. This task adds a BigQuery export via Log Router, per environment, using Terraform.

## Guardrails
- Do not change Python code or function entrypoints.
- Keep repo layout intact; edit only `infra/{dev,prod}`.
- Keep changes minimal, explicit, and easy to roll back.

## Scope
- Terraform only (dev and prod). No new services; reuse existing projects.
- Export only probe envelopes using a tight Log Router filter.

## Goals
1. Create (or reuse) a BigQuery dataset for probe logs.
2. Add a Log Router sink filtered to probe envelopes that writes to the dataset.
3. Grant sink writer IAM on the dataset.
4. Make the feature toggleable via variables (enabled by default).

## Variables to Add
Add these to `infra/dev/variables.tf` and `infra/prod/variables.tf` with sensible defaults:
- `bq_dataset_id` (string, default `"payment_probe"`)
- `bq_location` (string, default `"US"`)
- `enable_bq_sink` (bool, default `true`)
- `bq_table_expiration_days` (number, default `null` → no expiration)

## Resources (per env in `main.tf`)
- `google_bigquery_dataset.probe`:
  - `dataset_id = var.bq_dataset_id`
  - `location = var.bq_location`
  - Optional: `default_table_expiration_ms = var.bq_table_expiration_days == null ? null : var.bq_table_expiration_days * 24 * 60 * 60 * 1000`
  - Labels include `env = local.env`.

- `google_logging_project_sink.probe_to_bq` (create only when `var.enable_bq_sink`):
  - `name = "probe-to-bq"`
  - `destination = "bigquery.googleapis.com/projects/${var.project_id}/datasets/${var.bq_dataset_id}"`
  - `filter = "jsonPayload.source=\"gcp.payment-probe\""`
    - Optional hardening: append `AND jsonPayload.event.schema_version="v1"`.
  - `include_children = false`

- `google_bigquery_dataset_iam_member.sink_writer` (depends on sink):
  - `dataset_id = google_bigquery_dataset.probe.dataset_id`
  - `role = "roles/bigquery.dataEditor"`
  - `member = google_logging_project_sink.probe_to_bq.writer_identity`

Note: Sinks are created in the project-level Log Router; the `writer_identity` is a service account that needs dataset IAM.

## Plan/Apply and Verify
1. `cd infra/dev && terraform init && terraform plan -var-file=variables.tfvars`
2. `terraform apply -var-file=variables.tfvars`
3. Trigger a probe invocation (example):
   - `PROJECT=payments-test-runner-dev`
   - `gcloud pubsub topics publish tsgpayments-topic-us-central1 --message='{"action":"run"}' --project="$PROJECT"`
4. Confirm sink and dataset:
   - `gcloud logging sinks list --project="$PROJECT"`
   - `bq ls --project_id "$PROJECT" ${PROJECT}:$(terraform output -raw bq_dataset_id 2>/dev/null || echo payment_probe)`
5. Check rows (on the auto-created _AllLogs table):
   - `bq head --project_id "$PROJECT" -n 5 "$PROJECT:payment_probe._AllLogs"`
   - or count recent envelopes:
     - `bq query --use_legacy_sql=false 'SELECT COUNT(1) FROM `"$PROJECT"`.payment_probe._AllLogs WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 HOUR) AND JSON_VALUE(jsonPayload.source) = "gcp.payment-probe"'`

## Acceptance Criteria
- BigQuery dataset exists in the configured location.
- Probe envelopes are exported to BigQuery (rows present after invocations).
- Only probe envelopes are exported (filter works).
- Toggling `enable_bq_sink` off plans to remove the sink while keeping the dataset.

## Out of Scope
- Pub/Sub sink and Splunk forwarding (separate prompts).
- Alerts/metrics (can be added later).
