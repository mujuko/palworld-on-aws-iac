output "server_address" {
  description = "Address friends enter in Palworld. Null while server_enabled is false."
  value       = var.server_enabled ? "${aws_eip.server[0].public_ip}:${var.game_port}" : null
}

output "instance_id" {
  description = "EC2 instance ID used with AWS Systems Manager Session Manager."
  value       = var.server_enabled ? aws_instance.server[0].id : null
}

output "save_volume_id" {
  description = "Persistent EBS volume containing /Saved."
  value       = aws_ebs_volume.saves.id
}

output "backup_bucket" {
  description = "Private, versioned S3 bucket containing exportable save archives."
  value       = aws_s3_bucket.backups.id
}

output "credentials_secret_arn" {
  description = "Secrets Manager ARN containing the Palworld player and administrator passwords."
  value       = aws_secretsmanager_secret.palworld.arn
}
