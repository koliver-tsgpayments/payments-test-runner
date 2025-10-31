# BigQuery & Splunk Prompt Pack

This note captures refined prompts tailored to the current payments test runner proof of concept. The prompts keep the working shape of the repo intact while guiding future AI sessions to extend logging and Terraform in a controlled way.

## How to Use
- Start a new AI session with **Prompt 1** to load context and guardrails.
- Once the assistant acknowledges, paste **Prompt 2** to request the concrete implementation work.
- Keep **Prompt 3** for a follow-up session when you are ready to wire the Splunk forwarding toggle.

---

### Prompt 1 — Baseline Context & Guardrails
You are assisting on a Google Cloud Platform (GCP) project that runs “payment probe” Cloud Functions on schedules across multiple regions. The repository structure is stable and must remain recognizable:
- Runtime code lives under `functions/` (e.g., `functions/processors/_runner.py`, `functions/processors/tsg.py`, `functions/processors/worldpay.py`, `functions/main.py`).
- Terraform per-environment configurations are under `infra/{dev,prod}` with existing variables and Cloud Scheduler → Pub/Sub → Cloud Functions wiring.
- Tests run with `pytest` and currently cover the processors in `tests/test_processors.py`.
- HTTP probes use the `requests` library; keep dependencies minimal.

Current behaviour (which must keep working):
- Scheduler publishes to Pub/Sub topics, which trigger Cloud Functions Gen 2 processors.
- Each processor calls `execute()` in `functions/processors/_runner.py`, which returns a dict and logs JSON via the standard `logging` module.
- Environment variables `ENV` and `REGION` are already injected via Terraform. The code also executes successfully under `scripts/local_server.py`.

General guardrails:
1. Do not rename or relocate existing modules, functions, or Terraform roots unless absolutely necessary. Additive changes are preferred.
2. Keep the working proof of concept green: existing tests must pass; local workflows (like `scripts/local_server.py`) should continue to run.
3. No secrets in source; keep configuration in Terraform variables or Secret Manager.
4. New Python modules should live under `functions/`, and new Terraform resources should slot into the existing `infra/{env}` layout (add modules/files only if they integrate cleanly).
5. Logging must remain structured JSON and compatible with Cloud Logging exporters.

When you provide code, include reasoning about backward compatibility and call out any required manual steps (e.g., Terraform state updates). Ask before making invasive refactors.

Acknowledge that you understand the project shape, the guardrails, and that the next prompt will describe the BigQuery and Pub/Sub logging work.

---

### Prompt 2 — BigQuery & Pub/Sub Sinks
We are extending the payments probe project described earlier. Apply the guardrails from Prompt 1. The current system uses Scheduler → Pub/Sub → Cloud Functions (Gen 2); each processor invokes `functions/processors/_runner.execute`. The standard log envelope in Python is already implemented; this prompt focuses on exporting logs to BigQuery and Pub/Sub via Log Router and leaving room for a future Splunk integration. Keep the solution simple, readable, and maintainable.

## Goals
1. Use the existing **standard, versioned log envelope**; do not modify Python logging in this prompt.
2. Keep writing logs to **Cloud Logging** (structured) and export them via sinks to:
   - **BigQuery** (dataset for analytics)
   - **Pub/Sub** (integration bus for Splunk or other downstreams)
3. Provide a **toggleable** Splunk forwarding path that is disabled by default but scaffolded for the future.
4. Manage infrastructure with Terraform. CI/CD already uploads artifacts to GCS; Terraform deploys per-environment.
5. Provide stepwise testing checkpoints so the human operator can validate progress between steps.

## Constraints & Style
- Keep existing module layout; add new files under `functions/` rather than creating a new top-level package.
- Prefer minimal, explicit Python. Use stdlib + existing dependencies (`requests`, `google-cloud-logging`, etc.).
- Maintain structured JSON logging with a small, stable envelope. Never emit PII.
- No secrets in code. Pull sensitive values from Secret Manager or Terraform variables.
- Terraform: extend `infra/{dev,prod}` with new variables/resources. Feature flags (e.g., Splunk toggle) belong in Terraform vars.
- Keep module boundaries clean (e.g., dedicated logging helper module, optional Terraform modules under `infra/modules` if needed).

## Python Work (Out of Scope Here)
The Python log envelope is already in place. Do not change function names, signatures, or logging behavior. Focus this prompt on Terraform sinks and Splunk scaffolding only.

## Terraform Work
Within `infra/dev` and `infra/prod` (reusing their structure):
1. Extend variables in each environment to include:
   - `log_name` (default `"payment-probe"`).
   - `bq_dataset_id` (default `"payment_probe"`).
   - `pubsub_topic_name` (default `"probe-logs"`).
   - `enable_splunk_forwarding` (bool, default `false`).
   - Optional tuning variables like `log_retention_days` and `bq_table_expiration_days`.

2. Add Terraform resources (either inline or via a small module) for:
   - BigQuery dataset (US, time partitioned, optional expiration) and optional table.
   - Log Router sink to BigQuery filtering the custom log name and schema version.
   - Pub/Sub topic plus Log Router sink with the same filter; include a dead-letter topic.
   - IAM bindings so sink writers can publish to Pub/Sub and write to BigQuery.

3. Scaffold (but gate behind `enable_splunk_forwarding`) the future Splunk forwarder:
   - When enabled, create a subscription on the Pub/Sub topic with DLQ.
   - Leave commented guidance or ready-to-fill stubs for a Dataflow Flex template job or Cloud Run forwarder using Secret Manager for HEC credentials. The actual job need not be fully implemented yet, but the Terraform flag should be wired.

4. Optional but recommended: log-based metric (`probe_non_ok_count`) and alert policy emailing `var.ops_email` or equivalent.

5. Update or add a short README snippet under `infra/` documenting `gcloud logging read`, `bq query`, and Pub/Sub subscription commands for validation.

## Alerting Best Practices (Current Flow)
Keep alerting native to GCP so it works before Splunk is enabled:
- Create logs-based metrics that filter the custom log name where `jsonPayload.event.status != "OK"` and another percentile metric on `jsonPayload.event.latency_ms` to watch for slow regions.
- Attach Cloud Monitoring alert policies to those metrics (for example, ≥3 non-OK events in 5 minutes) and reuse existing notification channels such as email, PagerDuty, or Slack webhooks.
- Enable Pub/Sub dead-letter topics for each Scheduler→Pub/Sub trigger and surface DLQ messages via a lightweight Cloud Function or push endpoint so publish failures raise immediate alerts.
- Consider a scheduled BigQuery job that emails or posts a daily summary of error and latency trends; it gives visibility until Splunk dashboards are live.
- Make sure Terraform documents any manual API enables or notification-channel prerequisites so on-call runbooks stay accurate.

## Deliverables & Checkpoints
- Terraform updates (environment variables, sinks, dataset, topics, optional alerting).
- README snippet with quick verification commands.
- Stepwise checkpoints after major milestones:
  1. Terraform plan/apply in dev (confirm sinks, dataset, topic)
  2. Cloud Logging verification query
  3. BigQuery query sanity check
  4. Pub/Sub message inspection
  5. Splunk forwarding toggle test (future)

Explain any Terraform state considerations, note any manual steps (e.g., enabling APIs), and confirm existing processors continue to function.

---

### Prompt 3 — Future Splunk Forwarding Enablement
(Use after Prompt 2 work is merged.)
We now have the common log envelope, BigQuery dataset, and Pub/Sub sink in place. Extend the Terraform and Python as needed to turn on the Splunk forwarding path guarded by `enable_splunk_forwarding`.

Focused tasks:
1. Finalize the Pub/Sub subscription (`probe-logs-for-splunk`) with an attached dead-letter topic and appropriate IAM. Confirm Terraform switches it on only when the flag is true.
2. Choose one forwarding approach (Dataflow Flex template or Cloud Run service) and provide a minimal, production-ready scaffold that can be parameterized with Secret Manager values for Splunk HEC URL/token. Avoid hard-coding secrets.
3. Update documentation with runbooks for enabling the feature in dev, testing (e.g., temporary Splunk HEC mock), and rolling out to prod.
4. Add or update tests/documentation to ensure the Python code gracefully handles the flag (e.g., environment variables or config to attach Splunk metadata without emitting when disabled).

Respect all guardrails: keep existing processors stable, avoid breaking tests, and confirm Terraform plans cleanly when the flag is false (no resources created). Provide guidance for state migrations if resources toggle between states.
