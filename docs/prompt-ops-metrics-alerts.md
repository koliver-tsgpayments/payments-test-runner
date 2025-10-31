# Prompt — Logs-based Metrics and Alerts (Terraform Only)

Add basic ops visibility for probe logs using logs-based metrics and alerting. No Python changes.

## Guardrails
- Edit only `infra/{dev,prod}`.
- Keep configuration minimal and easy to toggle.

## Scope
- Create two logs-based metrics and simple alert policies per environment.

## Goals
1. Metric: `probe_non_ok_count` — count where `event.status != "OK"`.
2. Metric: `probe_latency_ms` — distribution on `event.latency_ms`.
3. Alert: errors burst — e.g., ≥3 non-OKs in 5 minutes.
4. Alert: high latency — e.g., p95 > threshold over 5 minutes (MQL-based).

## Variables to Add
Add to `infra/dev/variables.tf` and `infra/prod/variables.tf`:
- `enable_ops_alerts` (bool, default `false`)
- `ops_notification_channel_id` (string, default `null`)  # Monitoring channel ID
- `latency_p95_threshold_ms` (number, default `2000`)

## Resources (per env in `main.tf`)
- `google_logging_metric.probe_non_ok_count`:
  - `filter = "jsonPayload.source=\"gcp.payment-probe\" AND jsonPayload.event.status!=\"OK\""`
  - `metric_descriptor.metric_kind = "DELTA"`, `value_type = "INT64"`
- `google_logging_metric.probe_latency_ms`:
  - `filter = "jsonPayload.source=\"gcp.payment-probe\""`
  - `metric_descriptor.metric_kind = "DELTA"`, `value_type = "DISTRIBUTION"`, buckets as defaults

- Alerts (created when `enable_ops_alerts` and `ops_notification_channel_id` set):
  - `google_monitoring_alert_policy.probe_errors_burst`: threshold on `logging.googleapis.com/user/probe_non_ok_count` using a rate or sum over 5m.
  - `google_monitoring_alert_policy.probe_latency_p95`: MQL condition on p95 of `logging.googleapis.com/user/probe_latency_ms` vs `var.latency_p95_threshold_ms`.

Example MQL (for `probe_latency_p95`):
```
fetch logging.googleapis.com/user/probe_latency_ms
| align delta(5m)
| every 1m
| group_by [], [value_latency_p95: percentile(value.delta, 95)]
| condition gt(value_latency_p95, ${var.latency_p95_threshold_ms})
```

## Plan/Apply and Verify
1. `cd infra/dev && terraform init && terraform plan -var-file=variables.tfvars`
2. `terraform apply -var-file=variables.tfvars`
3. Generate a few errors (e.g., temporarily point a processor URL to a 404) to see `probe_non_ok_count` grow.
4. Check:
   - `gcloud logging metrics list --project="$PROJECT" | grep probe_`
   - `gcloud monitoring alert-policies list --project="$PROJECT"`

## Acceptance Criteria
- Metrics appear and populate in Monitoring within a few minutes.
- Alerts evaluate correctly when enabled and send to the provided channel.
- No impact to function runtime.

## Out of Scope
- Splunk dashboards and forwarding; handled in separate prompts.
