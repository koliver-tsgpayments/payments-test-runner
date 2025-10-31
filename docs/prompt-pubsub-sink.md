# Prompt — Pub/Sub Export Sink (Terraform Only)

Add a Pub/Sub export via Log Router to feed Splunk (later) and other consumers. No Python changes.

## Guardrails
- Edit only `infra/{dev,prod}`. Keep module layout intact.
- No app/runtime changes; producers remain untouched.

## Scope
- Terraform resources per environment: topic(s), sink, and IAM.
- Toggleable via variables (disabled by default).

## Goals
1. Create a Pub/Sub topic for probe logs (plus a DLQ topic for future subscribers).
2. Add a Log Router sink filtered to probe envelopes that publishes to the topic.
3. Grant the sink `writer_identity` permission to publish.
4. Make it toggleable with `enable_pubsub_sink`.

## Variables to Add
Add to `infra/dev/variables.tf` and `infra/prod/variables.tf`:
- `enable_pubsub_sink` (bool, default `false`)
- `pubsub_topic_name` (string, default `"probe-logs"`)
- `pubsub_dlq_topic_name` (string, default `"probe-logs-dlq"`)

## Resources (per env in `main.tf`)
- `google_pubsub_topic.probe_logs` (created when `enable_pubsub_sink`)
- `google_pubsub_topic.probe_logs_dlq` (created when `enable_pubsub_sink`)
- `google_logging_project_sink.probe_to_pubsub` (created when `enable_pubsub_sink`):
  - `destination = "pubsub.googleapis.com/projects/${var.project_id}/topics/${var.pubsub_topic_name}"`
  - `filter = "jsonPayload.source=\"gcp.payment-probe\""` (optionally add `AND jsonPayload.event.schema_version="v1"`)
  - `include_children = false`
- `google_pubsub_topic_iam_member.sink_publisher`:
  - `topic = google_pubsub_topic.probe_logs.name`
  - `role = "roles/pubsub.publisher"`
  - `member = google_logging_project_sink.probe_to_pubsub.writer_identity`

Notes:
- DLQ topic is for future consumers (e.g., Splunk forwarder subscription) to dead-letter to; the sink itself does not use a DLQ.

## Plan/Apply and Verify
1. `cd infra/dev && terraform init && terraform plan -var-file=variables.tfvars`
2. `terraform apply -var-file=variables.tfvars`
3. Trigger a probe invocation:
   - `PROJECT=payments-test-runner-dev`
   - `gcloud pubsub topics publish tsgpayments-topic-us-central1 --message='{"action":"run"}' --project="$PROJECT"`
4. Create a temporary subscription to verify messages:
   - `gcloud pubsub subscriptions create probe-logs-tmp --topic=probe-logs --project="$PROJECT"`
   - `gcloud pubsub subscriptions pull --auto-ack probe-logs-tmp --project="$PROJECT" --limit=5`
   - `gcloud pubsub subscriptions delete probe-logs-tmp --project="$PROJECT"`

## Acceptance Criteria
- Topic exists; sink publishes only probe envelopes to it.
- Toggling `enable_pubsub_sink` off removes the sink (topics can remain for consumers).
- No changes to function runtime or local server.

## Out of Scope
- Splunk forwarder (separate prompt); attach subscriptions/forwarders later.
