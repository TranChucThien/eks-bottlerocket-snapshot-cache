variable "name" {
  description = "Identifier name for the EC2 instance"
  type        = string
}

variable "ami_id" {
  description = "The ID of the Bottlerocket AMI. If not provided, will use SSM parameter to get latest."
  type        = string
  default     = ""
}

variable "ami_ssm_parameter" {
  description = "SSM parameter path for Bottlerocket AMI ID"
  type        = string
  default     = "/aws/service/bottlerocket/aws-k8s-1.24/x86_64/latest/image_id"
}

variable "instance_type" {
  description = "EC2 instance type to launch"
  type        = string
  # default     = "t2.small"
}

variable "subnet_id" {
  description = "Subnet ID to launch the instance"
  type        = string
}

variable "additional_iam_policies" {
  description = "List of additional IAM policy ARNs to attach to the instance role"
  type        = list(string)
  default     = []
}

variable "user_data" {
  description = "User data for Bottlerocket instance (TOML format)"
  type        = string
  default     = <<-EOT
    [settings.host-containers.admin]
    enabled = true
  EOT
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
