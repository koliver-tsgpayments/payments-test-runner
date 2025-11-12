# Prompt — Splunk Forwarder via Dataflow (Terraform Only)

Add a streaming forwarder from Pub/Sub to Splunk using the Google‑provided Dataflow template. No Python changes.

## Guardrails
- Edit only `infra/{dev,prod}`. Keep module layout intact.
- No app/runtime changes; producers remain untouched.
- Do not modify existing sinks; add new resources behind a feature flag.

## Context
- Probe envelopes are already exported to Pub/Sub via the project Log Router sink (topic: `probe-logs`).
- We want a reliable, near‑real‑time path to Splunk HEC using Dataflow.

## Scope
- Terraform resources per environment to run a Dataflow streaming job that reads from a dedicated subscription on `probe-logs` and writes to Splunk HEC.
- Toggleable via variables (disabled by default) and fully parameterized.

## Variables to Add (per env variables.tf)
- `enable_splunk_forwarder` (bool, default `false`)
- `splunk_hec_url` (string) — e.g., `https://splunk.example.com:8088` (must match an FQDN in the HEC certificate SAN; no trailing slash)
- `splunk_hec_token` (string, sensitive) — HEC token with write privileges
- `splunk_hec_insecure_ssl` (bool, default `false`) — allow insecure certs (dev only)
- `splunk_index` (string, default `null`) — optional index override
- `splunk_source` (string, default `null`) — optional source override
- `splunk_sourcetype` (string, default `payment_probe`) — default sourcetype
- `splunk_batch_count` (number, default `500`) — events per batch
- `splunk_batch_bytes` (number, default `1048576`) — bytes per batch (~1 MiB)
- `splunk_batch_interval_sec` (number, default `5`) — flush interval
- `splunk_max_workers` (number, default `3`) — Dataflow autoscaling cap
- `splunk_machine_type` (string, default `n1-standard-2`) — Dataflow worker type
- `splunk_enable_streaming_engine` (bool, default `false`) — enable Dataflow Streaming Engine (forces a new job when toggled)
- `dataflow_region` (string, default same as project default)
- `dataflow_staging_bucket` (string) — GCS bucket for staging/temp
- `pubsub_subscription_name` (string, default `probe-logs-splunk`) — subscription to create on `probe-logs`
- `pubsub_dlq_topic_name` (string, default `probe-logs-dlq`) — dead‑letter topic for failed HEC posts

## Resources to Add (per env main.tf)
- `google_pubsub_subscription.splunk` (created when `enable_splunk_forwarder`):
  - `topic = google_pubsub_topic.probe_logs.name`
  - Configure ack deadline (e.g., 30s) and message retention as needed
- `google_service_account.dataflow_splunk` (optional; else reuse default Compute SA)
- IAM bindings:
  - SA → `roles/pubsub.subscriber` on the subscription
  - SA → `roles/dataflow.worker`
  - SA → `roles/storage.objectAdmin` on `dataflow_staging_bucket`
  - SA → `roles/compute.networkUser` on the chosen network (if using VPC/NAT)
- `google_dataflow_job.splunk` (streaming):
  - Use the public template: "Cloud Pub/Sub to Splunk"
  - For classic templates, set `template_gcs_path` to the published template and pass `parameters` map
  - Mark as `on_delete = cancel` and `remove_when_deleted = true`
  - Parameters to include (names depend on template docs):
    - `inputSubscription` → the subscription path
    - `url` → `splunk_hec_url`
    - `token` → `splunk_hec_token`
    - `batchCount`, `batchSize`, `batchInterval` (map from the variables above)
    - `disableCertificateValidation` based on `splunk_hec_insecure_ssl`
    - `index`, `source`, `sourcetype` when provided
    - `deadletterTopic` → DLQ topic path

Notes:
- Prefer regional Dataflow placement (`dataflow_region`) aligned with Pub/Sub region.
- If the template is a Flex template instead, use `google_dataflow_flex_template_job` with `container_spec_gcs_path` + `parameters`.

## Plan/Apply and Verify
1. `cd infra/dev && terraform init && terraform plan -var-file=variables.tfvars`
2. In `infra/dev/variables.tfvars`, set:
   - `enable_pubsub_sink = true` (if not already)
   - `enable_splunk_forwarder = true`
   - `splunk_hec_url`, `splunk_hec_token`, and `dataflow_staging_bucket`
3. `terraform apply -var-file=variables.tfvars`
4. Confirm Dataflow job is running and subscription backlog drains.
5. Verify events in Splunk (search by `sourcetype=payment_probe` and `source=gcp.payment-probe`).

## Acceptance Criteria
- Subscription on `probe-logs` exists only when forwarder is enabled.
- Dataflow streaming job starts successfully and posts to HEC.
- Failures route to DLQ topic when configured.
- Toggling `enable_splunk_forwarder` plans to delete the Dataflow job and subscription.

## Out of Scope
- Creating networks/NAT or Splunk infrastructure; assume HEC is reachable.
- Transforming the envelope shape (forward as JSON as‑is).
