output "bq_dataset_id" {
  description = "BigQuery dataset ID used for probe logs."
  value       = google_bigquery_dataset.probe.dataset_id
}
