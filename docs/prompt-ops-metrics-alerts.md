# Prompt — Ops Metrics & Alerts (Terraform, demo‑ready)

Add a demo‑ready, native GCP monitoring setup that:
- Shows an end‑of‑day metrics dashboard (BigQuery) for each Cloud Function by region.
- Triggers error alerts that can be force‑generated for demos.
- Notifies via email using Cloud Monitoring channels.

This is infra‑first. No additional alerting bridges or runtimes are required.

## Guardrails
- Edit only `infra/{dev,prod}` and Terraform modules. Keep layout intact.
- No changes to existing app code.
- Keep alerts low‑noise and toggleable per environment.

## Scope
- Daily metrics dashboard (BigQuery) per Cloud Function, grouped by region.
- Error alerting from logs/metrics via Cloud Monitoring email channels.
- One‑command, safe demo triggers (no prod traffic harm).

---

## Phase 1 — Daily Metrics via BigQuery Dashboard
Use the existing BigQuery sink of probe logs to power a dashboard. No email infrastructure or reporter service needed.

Recommended BigQuery-only path:
- Logs are exported to dataset `payment_probe` (see `bq_dataset_id`) into the unified partitioned table `_AllLogs`.
- Build a Looker Studio dashboard against `_AllLogs`, or create a daily aggregated table via a Scheduled Query and point the dashboard at that table for faster loads.

Option A — Direct dashboard on `_AllLogs` (zero infra):
- Use this SQL for “Yesterday” in your data source:
```
DECLARE run_date DATE DEFAULT DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY);

WITH src AS (
  SELECT
    DATE(timestamp) AS day,
    jsonPayload.event.function AS function,
    jsonPayload.event.region   AS region,
    jsonPayload.event.status   AS status,
    CAST(jsonPayload.event.latency_ms AS INT64) AS latency_ms
  FROM `PROJECT_ID.payment_probe._AllLogs`
  WHERE timestamp >= TIMESTAMP(run_date)
    AND timestamp < TIMESTAMP(DATE_ADD(run_date, INTERVAL 1 DAY))
    AND jsonPayload.source = "gcp.payment-probe"
    AND jsonPayload.event.schema_version = "v1"
)
SELECT
  day,
  region,
  function,
  COUNT(1) AS invocations,
  COUNTIF(status = "ERROR") AS errors,
  COUNTIF(status != "ERROR") AS ok,
  SAFE_DIVIDE(COUNTIF(status = "ERROR"), COUNT(1)) AS error_rate,
  ROUND(AVG(latency_ms), 1) AS avg_latency_ms,
  APPROX_QUANTILES(latency_ms, 100)[OFFSET(50)] AS p50_latency_ms,
  APPROX_QUANTILES(latency_ms, 100)[OFFSET(95)] AS p95_latency_ms
FROM src
GROUP BY day, region, function
ORDER BY region, function;
```

Option B — Scheduled Query to `eod_metrics` (faster, optional):
- Create a BigQuery table for daily aggregates and a Scheduled Query that populates it.
- Terraform sketch (per env `main.tf`):
```
resource "google_bigquery_table" "eod_metrics" {
  dataset_id = var.bq_dataset_id
  table_id   = var.eod_table_id
  deletion_protection = false

  time_partitioning {
    type  = "DAY"
    field = "day"
  }

  schema = jsonencode([
    { name = "day",             type = "DATE",    mode = "REQUIRED" },
    { name = "region",          type = "STRING",  mode = "REQUIRED" },
    { name = "function",        type = "STRING",  mode = "REQUIRED" },
    { name = "invocations",     type = "INT64",   mode = "REQUIRED" },
    { name = "errors",          type = "INT64",   mode = "REQUIRED" },
    { name = "ok",              type = "INT64",   mode = "REQUIRED" },
    { name = "error_rate",      type = "FLOAT64", mode = "REQUIRED" },
    { name = "avg_latency_ms",  type = "FLOAT64", mode = "REQUIRED" },
    { name = "p50_latency_ms",  type = "INT64",   mode = "REQUIRED" },
    { name = "p95_latency_ms",  type = "INT64",   mode = "REQUIRED" }
  ])
}
```

Then schedule the daily aggregation:
```
resource "google_bigquery_data_transfer_config" "eod_metrics" {
  count          = var.enable_eod_bq_agg ? 1 : 0
  display_name   = "EOD Probe Metrics"
  data_source_id = "scheduled_query"
  location       = var.bq_location
  schedule       = var.eod_schedule  # e.g., "every day 23:59"

  params = {
    destination_table_name_template = var.eod_table_id   # e.g., "eod_metrics"
    write_disposition               = "WRITE_TRUNCATE"
    partitioning_field              = "day"
    query = <<SQL
DECLARE run_date DATE DEFAULT DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY);
CREATE TEMP TABLE tmp AS
WITH src AS (
  SELECT
    DATE(timestamp) AS day,
    jsonPayload.event.function AS function,
    jsonPayload.event.region   AS region,
    jsonPayload.event.status   AS status,
    CAST(jsonPayload.event.latency_ms AS INT64) AS latency_ms
  FROM `${var.project_id}.${var.bq_dataset_id}._AllLogs`
  WHERE timestamp >= TIMESTAMP(run_date)
    AND timestamp < TIMESTAMP(DATE_ADD(run_date, INTERVAL 1 DAY))
    AND jsonPayload.source = "gcp.payment-probe"
    AND jsonPayload.event.schema_version = "v1"
)
SELECT
  day,
  region,
  function,
  COUNT(1) AS invocations,
  COUNTIF(status = "ERROR") AS errors,
  COUNTIF(status != "ERROR") AS ok,
  SAFE_DIVIDE(COUNTIF(status = "ERROR"), COUNT(1)) AS error_rate,
  ROUND(AVG(latency_ms), 1) AS avg_latency_ms,
  APPROX_QUANTILES(latency_ms, 100)[OFFSET(50)] AS p50_latency_ms,
  APPROX_QUANTILES(latency_ms, 100)[OFFSET(95)] AS p95_latency_ms
FROM src
GROUP BY day, region, function;

DELETE FROM `${var.project_id}.${var.bq_dataset_id}.${var.eod_table_id}` WHERE day = run_date;
INSERT `${var.project_id}.${var.bq_dataset_id}.${var.eod_table_id}` SELECT * FROM tmp;
SQL
  }
}
```

Variables to add (per env `variables.tf`):
- `enable_eod_bq_agg` (bool, default `false`)
- `eod_table_id` (string, default `"eod_metrics"`)
- `eod_schedule` (string, default `"every day 23:59"`)

Dashboard: Point Looker Studio at `${project_id}.${bq_dataset_id}.eod_metrics` (or `_AllLogs` for Option A). Use a date control defaulting to “Yesterday”, and dimensions Region and Function with metrics Invocations, OK, Errors, Error %, p50, p95, Avg latency.

### Notes
- Looker Studio (Data Studio) dashboards aren’t managed by Terraform. The IaC here provisions the data model (tables/views) and an optional Scheduled Query.

---

## Phase 2 — Error Alerting (demo‑able)
We’ll alert on function errors and make generating a demo error a one‑liner.

Clarification on email for alerts:
- Cloud Monitoring can send email directly using its built‑in email notification channels. No third‑party provider or SMTP is needed for alert notifications.
- GCP’s port‑25 restrictions don’t apply here, because the platform sends the alert emails, not your workloads.

### Variables to Add (per env `variables.tf`)
- `enable_ops_alerts` (bool, default `false`)
- `monitoring_email_recipients` (list(string), default `[]`) — email(s) to notify
- `probe_error_threshold` (number, default `1`) — errors to trigger over window
- `probe_error_window_sec` (number, default `300`)

### Resources to Add (per env `main.tf`)
1) Email notification channel(s)
```
resource "google_monitoring_notification_channel" "ops_email" {
  for_each    = var.enable_ops_alerts ? toset(var.monitoring_email_recipients) : []
  display_name = "Ops Alerts Email: ${each.value}"
  type         = "email"
  labels       = { email_address = each.value }
}
```

2) Logs‑based metric for Cloud Function errors
```
resource "google_logging_metric" "cf_error_log_count" {
  count       = var.enable_ops_alerts ? 1 : 0
  name        = "cf_error_log_count"
  description = "Count of Cloud Function ERROR logs"

  filter = "resource.type=\"cloud_function\" AND severity>=ERROR"

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
    labels { key = "function", value_type = "STRING", description = "Function name" }
    labels { key = "region",   value_type = "STRING", description = "Region" }
  }
  label_extractors = {
    function = "EXTRACT(resource.labels.function_name)"
    region   = "EXTRACT(resource.labels.region)"
  }
}
```

3) Alert policy on error logs (fires fast, low noise)
```
resource "google_monitoring_alert_policy" "cf_errors" {
  count        = var.enable_ops_alerts ? 1 : 0
  display_name = "Cloud Function error logs >= ${var.probe_error_threshold} in ${var.probe_error_window_sec}s"
  combiner     = "OR"

  conditions {
    display_name = "Function error burst"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/cf_error_log_count\" resource.type=\"global\""
      comparison      = "COMPARISON_GT"
      threshold_value = var.probe_error_threshold
      duration        = "${var.probe_error_window_sec}s"

      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["metric.label.function", "metric.label.region"]
      }

      trigger { count = 1 }
    }
  }

  notification_channels = [for c in google_monitoring_notification_channel.ops_email : c.name]
}
```

Optional: metric‑based alert on execution failures (Gen 1)
```
resource "google_monitoring_alert_policy" "cf_failures" {
  count        = var.enable_ops_alerts ? 1 : 0
  display_name = "Cloud Function failures detected (5m)"
  combiner     = "OR"

  conditions {
    display_name = "Execution failures > 0"
    condition_threshold {
      filter          = "metric.type=\"cloudfunctions.googleapis.com/function/execution_count\" metric.label.status=\"failure\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "300s"
      aggregations { alignment_period = "60s", per_series_aligner = "ALIGN_DELTA" }
      trigger { count = 1 }
    }
  }

  notification_channels = [for c in google_monitoring_notification_channel.ops_email : c.name]
}
```

### Demo: create a safe error on demand
You can synthesize an error log that matches the alert without touching code:
```
gcloud logging write demo_error "Demo error for alerts" \
  --severity=ERROR \
  --resource=cloud_function \
  --resource-labels function_name=YOUR_FUNCTION,region=YOUR_REGION
```
This produces a single ERROR entry for the function in the region you specify and should trip the logs‑based alert instantly.

---

## Plan/Apply and Verify
1. `cd infra/dev && terraform init && terraform plan -var-file=variables.tfvars`
2. In `infra/dev/variables.tfvars`, add (example):
   ```
   # Daily metrics via BigQuery (no email)
   enable_eod_bq_agg = true
   eod_table_id      = "eod_metrics"
   eod_schedule      = "every day 23:59"

   # Error alerts
   enable_ops_alerts             = true
   monitoring_email_recipients   = ["you@yourdomain"]
   probe_error_threshold         = 1
   probe_error_window_sec        = 300

   ```
3. `terraform apply -var-file=variables.tfvars`
4. Verify:
   - BigQuery dataset has `_AllLogs` with recent probe rows.
   - If scheduled query enabled: table `eod_metrics` exists with a partition for yesterday.
   - Alert policies show OK; notification channels list your email address(es).

---

## Demo Script (copy/paste)
- Preview yesterday’s EOD metrics via BigQuery:
  - `bq query --use_legacy_sql=false "DECLARE run_date DATE DEFAULT DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY); WITH src AS (SELECT DATE(timestamp) AS day, jsonPayload.event.function AS function, jsonPayload.event.region AS region, jsonPayload.event.status AS status, CAST(jsonPayload.event.latency_ms AS INT64) AS latency_ms FROM \`$PROJECT.payment_probe._AllLogs\` WHERE timestamp >= TIMESTAMP(run_date) AND timestamp < TIMESTAMP(DATE_ADD(run_date, INTERVAL 1 DAY)) AND jsonPayload.source = 'gcp.payment-probe' AND jsonPayload.event.schema_version = 'v1') SELECT day, region, function, COUNT(1) AS invocations, COUNTIF(status='ERROR') AS errors, COUNTIF(status!='ERROR') AS ok, SAFE_DIVIDE(COUNTIF(status='ERROR'), COUNT(1)) AS error_rate, ROUND(AVG(latency_ms),1) AS avg_latency_ms, APPROX_QUANTILES(latency_ms,100)[OFFSET(50)] AS p50_latency_ms, APPROX_QUANTILES(latency_ms,100)[OFFSET(95)] AS p95_latency_ms FROM src GROUP BY day, region, function ORDER BY region, function;"`
- Force an error to trip alert:
  - `gcloud logging write demo_error "demo" --severity=ERROR --resource=cloud_function --resource-labels function_name=YOUR_FUNCTION,region=YOUR_REGION`
- Open the Looker Studio dashboard connected to BigQuery to demo the table and trends.

---

## Acceptance Criteria
- BigQuery dashboard (or `eod_metrics` table) shows, by region → function, the last 24h: invocations, failures, error rate, p50/p95 latency.
- Error alert fires on synthetic error and emails within minutes.
- Toggling `enable_eod_bq_agg`/`enable_ops_alerts` plans to remove any added infra.

## Notes / Out of Scope
- No email/reporting runtime is required for the BigQuery dashboard path.
- If functions are Gen 2, prefer Gen‑2 metrics; otherwise fall back to logs‑based alert shown above.
