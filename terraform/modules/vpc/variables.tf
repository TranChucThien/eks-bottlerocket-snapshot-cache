variable "name" {
  description = "Identifier name for the VPC"
  type        = string
  # default     = "my-vpc"
}

variable "vpc_cidr" {
  description = "CIDR block of the VPC"
  type        = string
  # default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid CIDR block."
  }
  
}

variable "azs" {
  description = "List of Availability Zones"
  type        = list(string)
  # default     = ["us-east-2a", "us-east-2b", "us-east-2c"]
}

variable "public_subnet_cidrs" {
  description = "List of CIDRs for public subnets"
  type        = list(string)
  # default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "private_subnet_cidrs" {
  description = "List of CIDRs for private subnets"
  type        = list(string)
  # default     = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
  # default = {
  #   Environment = "dev"
  #   Project     = "vpc-custom"
  # }
}
