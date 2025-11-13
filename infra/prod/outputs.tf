output "bq_dataset_id" {
  description = "BigQuery dataset ID used for probe logs."
  value       = module.stack.bq_dataset_id
}
