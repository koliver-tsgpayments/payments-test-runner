## TODO

- [X] Follow up with manager on the `constraints/gcp.resourceLocations` org policy. Current allowed values are `global`, `us`, and `in:us-central1-locations`, which blocks deploying Cloud Functions to regions like `us-east4`. Request an exception or update the policy if broader coverage is required.
- [X] Implement versioned structured log envelope across processors (one envelope per invocation), wire Google Cloud Logging handler, update README with filters.
- [X] Add BigQuery export sink via Log Router (Terraform in dev/prod). See docs/prompt-bq-sink.md
- [ ] Add Pub/Sub export sink via Log Router (Terraform in dev/prod). See docs/prompt-pubsub-sink.md
- [ ] Add logs-based metrics and simple alert policies (Terraform). See docs/prompt-ops-metrics-alerts.md
