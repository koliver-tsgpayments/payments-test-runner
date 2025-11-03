# Prompt — Minimal Ops Alerts (Terraform)

Add minimal, native GCP alerting around probe health and (optionally) Pub/Sub backlog. No Python changes.

## Guardrails
- Edit only `infra/{dev,prod}`. Keep module layout intact.
- No app/runtime changes; Terraform only.
- Keep alerts low-noise and toggleable.

## Scope
- One logs-based metric + alert for probe errors.
- Optional alert for Pub/Sub backlog on the future Dataflow subscription.

## Variables to Add (per env variables.tf)
- `enable_ops_alerts` (bool, default `false`) — create alerts when true
- `monitoring_notification_channels` (list(string), default `[]`) — channel IDs to notify
- `probe_error_threshold` (number, default `5`) — errors to trigger over window
- `probe_error_window_sec` (number, default `300`) — evaluation window seconds
- `enable_pubsub_backlog_alert` (bool, default `false`) — enable backlog alert
- `pubsub_alert_subscription_name` (string, default `null`) — subscription to watch (e.g., `probe-logs-splunk`)
- `pubsub_backlog_window_sec` (number, default `600`) — backlog sustained window

## Resources to Add (per env main.tf)
1) Logs‑based metric: probe error count

```
resource "google_logging_metric" "probe_error_count" {
  count       = var.enable_ops_alerts ? 1 : 0
  name        = "probe_error_count"
  description = "Count of probe ERROR envelopes"

  filter = "jsonPayload.source=\"gcp.payment-probe\" AND (jsonPayload.event.status=\"ERROR\" OR severity=ERROR)"

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
    labels {
      key         = "target"
      value_type  = "STRING"
      description = "Probe target"
    }
  }

  label_extractors = {
    target = "EXTRACT(jsonPayload.event.target)"
  }
}
```

2) Alert policy: probe errors burst

```
resource "google_monitoring_alert_policy" "probe_errors" {
  count        = var.enable_ops_alerts ? 1 : 0
  display_name = "Probe errors high (last ${var.probe_error_window_sec}s)"
  combiner     = "OR"

  conditions {
    display_name = "Errors >= ${var.probe_error_threshold} in ${var.probe_error_window_sec}s"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/probe_error_count\" resource.type=\"global\""
      comparison      = "COMPARISON_GT"
      threshold_value = var.probe_error_threshold
      duration        = "${var.probe_error_window_sec}s"

      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["metric.label.target"]
      }

      trigger { count = 1 }
    }
  }

  notification_channels = var.monitoring_notification_channels
}
```

3) Alert policy (optional): Pub/Sub backlog on Dataflow subscription

```
resource "google_monitoring_alert_policy" "pubsub_backlog" {
  count        = var.enable_ops_alerts && var.enable_pubsub_backlog_alert && var.pubsub_alert_subscription_name != null ? 1 : 0
  display_name = "Pub/Sub backlog high (subscription ${var.pubsub_alert_subscription_name})"
  combiner     = "OR"

  conditions {
    display_name = "Undelivered messages > 0 for ${var.pubsub_backlog_window_sec}s"
    condition_threshold {
      filter          = "metric.type=\"pubsub.googleapis.com/subscription/num_undelivered_messages\" resource.type=\"pubsub_subscription\" resource.label.subscription_id=\"${var.pubsub_alert_subscription_name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "${var.pubsub_backlog_window_sec}s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MAX"
      }

      trigger { count = 1 }
    }
  }

  notification_channels = var.monitoring_notification_channels
}
```

## Plan/Apply and Verify
1. `cd infra/dev && terraform init && terraform plan -var-file=variables.tfvars`
2. In `infra/dev/variables.tfvars`, add (example):
   ```
   enable_ops_alerts                = true
   monitoring_notification_channels = ["projects/$PROJECT/notificationChannels/123"]
   probe_error_threshold            = 5
   probe_error_window_sec           = 300
   # Optional when Dataflow/Splunk is added:
   # enable_pubsub_backlog_alert    = true
   # pubsub_alert_subscription_name = "probe-logs-splunk"
   # pubsub_backlog_window_sec      = 600
   ```
3. `terraform apply -var-file=variables.tfvars`
4. Confirm:
   - Logs-based metric appears in Monitoring Metrics Explorer.
   - Alert policies exist and show “OK” state.

## Acceptance Criteria
- Logs‑based metric counts ERROR envelopes and extracts `target` label.
- Alert fires when errors exceed threshold in the window.
- Optional backlog alert fires when undelivered messages persist for the configured window.
- Toggling `enable_ops_alerts` plans to remove all added policies/metrics.

## Out of Scope
- Creating notification channels (PagerDuty/Slack/email); pass existing channel IDs via variable.
- Dataflow job and subscription wiring (covered in prompt-splunk-dataflow.md).
