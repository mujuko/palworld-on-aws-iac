variable "aws_region" {
  description = "AWS region in which to create the server."
  type        = string
  default     = "ap-northeast-1"
}

variable "name" {
  description = "Name prefix used for AWS resources."
  type        = string
  default     = "palworld-friends"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$", var.name))
    error_message = "name must be 3-32 lowercase letters, numbers, or hyphens, and may not start or end with a hyphen."
  }
}

variable "allowed_cidrs" {
  description = "Public IPv4 CIDRs allowed to connect to the configured UDP game port. Use each member's public IP with /32."
  type        = list(string)

  validation {
    condition     = length(var.allowed_cidrs) > 0 && alltrue([for cidr in var.allowed_cidrs : can(cidrnetmask(cidr))])
    error_message = "allowed_cidrs must contain at least one valid IPv4 CIDR."
  }
}

variable "game_port" {
  description = "UDP port exposed by the host and used by the Palworld server."
  type        = number
  default     = 8211

  validation {
    condition     = var.game_port >= 1024 && var.game_port <= 65535 && floor(var.game_port) == var.game_port
    error_message = "game_port must be an integer between 1024 and 65535."
  }
}

variable "server_enabled" {
  description = "Whether the EC2 game server and its Elastic IP exist. Set false to remove compute while preserving saves and backups."
  type        = bool
  default     = true
}

variable "instance_type" {
  description = "EC2 instance type. r7i.xlarge provides 4 vCPU and 32 GiB RAM."
  type        = string
  default     = "r7i.xlarge"
}

variable "save_volume_size_gib" {
  description = "Size of the persistent gp3 save-data volume in GiB."
  type        = number
  default     = 100

  validation {
    condition     = var.save_volume_size_gib >= 20
    error_message = "save_volume_size_gib must be at least 20 GiB."
  }
}

variable "root_volume_size_gib" {
  description = "Size of the EC2 root gp3 volume used by the OS, Docker, and the extracted server image."
  type        = number
  default     = 50

  validation {
    condition     = var.root_volume_size_gib >= 40
    error_message = "root_volume_size_gib must be at least 40 GiB so the official image can be pulled and extracted."
  }
}

variable "palworld_image" {
  description = "Pinned official Palworld dedicated-server container image."
  type        = string
  default     = "ghcr.io/pocketpairjp/palserver:v1.0.5.102999"

  validation {
    condition     = startswith(var.palworld_image, "ghcr.io/pocketpairjp/palserver:") && !endswith(var.palworld_image, ":latest")
    error_message = "palworld_image must be a pinned ghcr.io/pocketpairjp/palserver image tag."
  }
}
