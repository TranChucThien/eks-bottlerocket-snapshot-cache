output "snapshot_id" {
  description = "EBS snapshot ID of the Bottlerocket data volume"
  value       = trimspace(data.local_file.snapshot_id.content)
}
