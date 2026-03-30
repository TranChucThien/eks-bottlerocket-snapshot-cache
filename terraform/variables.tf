variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
}

variable "project_name" {
  description = "Project name used as prefix for resource naming"
  type        = string
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid CIDR block."
  }
}

variable "azs" {
  description = "List of Availability Zones"
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "List of CIDRs for public subnets"
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "List of CIDRs for private subnets"
  type        = list(string)
}

variable "ami_ssm_parameter" {
  description = "SSM parameter path for Bottlerocket AMI ID"
  type        = string
  default     = "/aws/service/bottlerocket/aws-k8s-1.24/x86_64/latest/image_id"
}

variable "instance_type" {
  description = "EC2 instance type for Bottlerocket instance"
  type        = string
  default     = "t2.small"
}

variable "container_images" {
  description = "Comma-separated list of container images to cache"
  type        = string
  default     = "public.ecr.aws/eks-distro/kubernetes/pause:3.2"
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
