mock_provider "aws" {
  mock_data "aws_ec2_instance_type_offerings" {
    defaults = {
      locations = ["ap-northeast-1a"]
    }
  }

  mock_data "aws_ssm_parameter" {
    defaults = {
      value = "ami-0123456789abcdef0"
    }
  }
}

variables {
  allowed_cidrs = ["203.0.113.10/32"]
}

run "recommended_server_shape" {
  command = plan

  assert {
    condition     = aws_instance.server[0].instance_type == "r7i.xlarge"
    error_message = "The default server must have 4 vCPU and 32 GiB RAM."
  }

  assert {
    condition     = aws_ebs_volume.saves.type == "gp3" && aws_ebs_volume.saves.encrypted
    error_message = "Save data must use an encrypted gp3 EBS volume."
  }

  assert {
    condition     = aws_instance.server[0].root_block_device[0].volume_size >= 40
    error_message = "The root volume must have enough space to extract the official Docker image."
  }

  assert {
    condition     = one(aws_security_group.server.ingress).from_port == var.game_port && one(aws_security_group.server.ingress).to_port == var.game_port && one(aws_security_group.server.ingress).protocol == "udp"
    error_message = "The security group must expose only the configured UDP game port."
  }
}

run "compute_can_be_removed" {
  command = plan

  variables {
    server_enabled = false
  }

  assert {
    condition     = length(aws_instance.server) == 0 && length(aws_volume_attachment.saves) == 0
    error_message = "Disabling the server must remove compute and detach the persistent volume."
  }

  assert {
    condition     = aws_ebs_volume.saves.size == 100 && aws_s3_bucket.backups.force_destroy == false && aws_secretsmanager_secret.palworld.recovery_window_in_days == 7
    error_message = "Persistent saves, protected backups, and the credential container must remain in the plan."
  }
}
