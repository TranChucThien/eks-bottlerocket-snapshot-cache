variable "instance_id" {
  description = "EC2 instance ID"
  type        = string
}

variable "container_images" {
  description = "Comma-separated list of container images to cache"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}
