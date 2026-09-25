data "aws_ec2_instance_type_offerings" "selected" {
  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }

  location_type = "availability-zone"
}

data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_vpc" "main" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = var.name
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = var.name
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  availability_zone       = sort(data.aws_ec2_instance_type_offerings.selected.locations)[0]
  cidr_block              = "10.42.1.0/24"
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.name}-public"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.name}-public"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "server" {
  name_prefix = "${var.name}-"
  description = "Palworld game traffic only; administration uses SSM"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Palworld UDP from approved friends"
    protocol    = "udp"
    from_port   = var.game_port
    to_port     = var.game_port
    cidr_blocks = var.allowed_cidrs
  }

  egress {
    description = "Updates, SSM, container registry, and S3 backups"
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = var.name
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_s3_bucket" "backups" {
  bucket_prefix = "${var.name}-save-backups-"
  force_destroy = false

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket = aws_s3_bucket.backups.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "backups_tls" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.backups.arn,
      "${aws_s3_bucket.backups.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "backups" {
  bucket = aws_s3_bucket.backups.id
  policy = data.aws_iam_policy_document.backups_tls.json
}

resource "aws_iam_role" "server" {
  name_prefix = "${var.name}-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.server.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_secretsmanager_secret" "palworld" {
  name_prefix             = "${var.name}-credentials-"
  description             = "Palworld player and administrator passwords; values are managed outside OpenTofu"
  recovery_window_in_days = 7
}

removed {
  from = aws_secretsmanager_secret_version.palworld

  lifecycle {
    destroy = false
  }
}

data "aws_iam_policy_document" "server_access" {
  statement {
    sid       = "ListBackupBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.backups.arn]
  }

  statement {
    sid    = "ReadWriteBackupArchives"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
    ]
    resources = ["${aws_s3_bucket.backups.arn}/backups/*"]
  }

  statement {
    sid       = "ReadPalworldCredentials"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.palworld.arn]
  }
}

resource "aws_iam_role_policy" "server_access" {
  name_prefix = "palworld-access-"
  role        = aws_iam_role.server.id
  policy      = data.aws_iam_policy_document.server_access.json
}

resource "aws_iam_instance_profile" "server" {
  name_prefix = "${var.name}-"
  role        = aws_iam_role.server.name
}

resource "aws_ebs_volume" "saves" {
  availability_zone = aws_subnet.public.availability_zone
  type              = "gp3"
  size              = var.save_volume_size_gib
  iops              = 3000
  throughput        = 125
  encrypted         = true

  tags = {
    Name = "${var.name}-saves"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_instance" "server" {
  count = var.server_enabled ? 1 : 0

  ami                         = data.aws_ssm_parameter.al2023_ami.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.server.id]
  iam_instance_profile        = aws_iam_instance_profile.server.name
  associate_public_ip_address = true
  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/templates/user-data.sh.tftpl", {
    backup_bucket       = aws_s3_bucket.backups.id
    game_port           = var.game_port
    palworld_image      = var.palworld_image
    palworld_secret_arn = aws_secretsmanager_secret.palworld.arn
    palworld_settings   = jsonencode(var.palworld_settings)
    volume_id           = replace(aws_ebs_volume.saves.id, "-", "")
  })

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gib
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tags = {
    Name = var.name
  }

  depends_on = [
    aws_iam_role_policy.server_access,
    aws_iam_role_policy_attachment.ssm,
    aws_route_table_association.public,
  ]
}

resource "aws_volume_attachment" "saves" {
  count = var.server_enabled ? 1 : 0

  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.saves.id
  instance_id = aws_instance.server[0].id
}

resource "aws_eip" "server" {
  count = var.server_enabled ? 1 : 0

  domain = "vpc"

  tags = {
    Name = var.name
  }
}

resource "aws_eip_association" "server" {
  count = var.server_enabled ? 1 : 0

  allocation_id = aws_eip.server[0].id
  instance_id   = aws_instance.server[0].id
}
