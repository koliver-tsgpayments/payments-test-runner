# Demo: Ops Metrics, Alerts, and EOD Summary

This guide shows how to:
- Enable minimal, low-noise GCP alerts for probe errors (Terraform-only)
- Trigger demo errors on-demand (no code changes)
- Receive alerts via Email and Microsoft Teams
- Get an end-of-day (EOD) metrics summary by Cloud Function and region

## 1) Enable Terraform ops alerts
In `infra/dev/variables.tfvars` (and `infra/prod/variables.tfvars` if desired):

```
enable_ops_alerts                = true
monitoring_notification_channels = [
  "projects/$PROJECT/notificationChannels/<EMAIL_CHANNEL_ID>",
  "projects/$PROJECT/notificationChannels/<WEBHOOK_CHANNEL_ID>"
]
probe_error_threshold  = 5
probe_error_window_sec = 300

# Optional backlog alert (when Splunk/Dataflow is added):
# enable_pubsub_backlog_alert    = true
# pubsub_alert_subscription_name = "probe-logs-splunk"
# pubsub_backlog_window_sec      = 600
```

Then apply:
```
cd infra/dev
terraform init
terraform apply -var-file=variables.tfvars
```

What this provisions:
- Logs-based metric `probe_error_count` filtered to `source="gcp.payment-probe"`
- Alert policy that fires when errors exceed threshold within the window (grouped by `target`)
- Optional Pub/Sub backlog alert (disabled by default)

## 2) Wire notification channels (Email + Teams)

You can reuse existing channels or create new ones.

- Email: create via Cloud Console (Monitoring → Alerting → Notification channels → Email) or with gcloud:
  ```
  gcloud alpha monitoring channels create \
    --display-name="Ops Email" \
    --type=email \
    --channel-labels=email_address="ops@example.com" \
    --project=$PROJECT
  gcloud alpha monitoring channels list --project=$PROJECT
  ```

- Microsoft Teams: add an Incoming Webhook connector to your channel, copy the URL, then create a Webhook channel in Monitoring:
  ```
  TEAMS_WEBHOOK_URL="https://your-teams-webhook-url"  # from Teams
  gcloud alpha monitoring channels create \
    --display-name="Teams (Webhook)" \
    --type=webhook_tokenauth \
    --channel-labels=url="$TEAMS_WEBHOOK_URL" \
    --project=$PROJECT
  gcloud alpha monitoring channels list --project=$PROJECT
  ```

Paste the resulting channel IDs into `monitoring_notification_channels` and re-apply Terraform.

## 3) Demo errors (no code changes)
Emit a single probe-style ERROR envelope into Cloud Logging to exercise the logs-based metric and alert policy:

```
PROJECT=payments-test-runner-dev \
./scripts/demo_probe_error.sh \
  --target worldpay \
  --region us-west4 \
  --function run_worldpay \
  --http-status 503 \
  --latency-ms 250
```

This writes a structured log line with `source=gcp.payment-probe` and `status=ERROR`. The alert policy evaluates every minute; expect notifications to Email and Teams within a few minutes (respecting your `probe_error_threshold`/`probe_error_window_sec`).

## 4) End-of-day metrics email (per Function by Region)

You have two straightforward options:

### Option A — No code: Looker Studio scheduled email
- Ensure the BigQuery sink is enabled (default in this repo). Data lives in dataset `payment_probe`.
- Create a Looker Studio report against BigQuery. Use `scripts/bq_eod_metrics.sql` as a basis for a view.
- Build a simple table: Function, Region, Invocations, OK, Errors, Success %, p50, p95, avg latency.
- Schedule email delivery (daily, specific time zone) to your recipients.

Pros: zero new runtime; GUI-friendly. Cons: PDF email, no Teams post.

### Option B — Programmatic: Cloud Scheduler → Function → Email + Teams
- Add a small Cloud Function (or Cloud Run job) that:
  - Runs the query in `scripts/bq_eod_metrics.sql` for the previous UTC day
  - Formats a text/HTML summary
  - Sends email via SendGrid (API key in Secret Manager)
  - Posts to Teams via the same webhook used above
- Trigger daily with Cloud Scheduler at your chosen local time.

This repo doesn’t yet include the reporter function artifact. If you want, I can add a minimal Python function and Terraform to wire Scheduler + Secrets + Function. You’d only need to upload the ZIP to your release bucket.

## 5) Verify quickly
- Logs-based metric: Monitoring → Metrics Explorer → `logging.googleapis.com/user/probe_error_count`
- Alerts: Monitoring → Alerting → Alerting policies → `Probe errors high...`
- BigQuery: run the EOD SQL locally to spot-check yesterday’s metrics:
  ```
  PROJECT=payments-test-runner-dev
  bq query --use_legacy_sql=false --project_id="$PROJECT" < scripts/bq_eod_metrics.sql
  ```

## Notes
- The demo error path is safe: it only writes a synthetic log line to Cloud Logging.
- Notification channels are external to Terraform here by design; pass channel IDs via variable.
- If you need me to add a turn-key daily reporter function, say the word and I’ll scaffold it.

