provider "aws" {
  region = var.aws_region
}

locals {
  name = "${var.project_name}-${var.environment}"
  tags = merge(var.tags, {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
  })
}

module "vpc" {
  source = "./modules/vpc"

  name                 = local.name
  vpc_cidr             = var.vpc_cidr
  azs                  = var.azs
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  tags                 = local.tags
}

module "ec2" {
  source = "./modules/ec2"

  name              = "${local.name}-bottlerocket"
  ami_ssm_parameter = var.ami_ssm_parameter
  instance_type     = var.instance_type
  subnet_id         = module.vpc.public_subnet_ids[0]
  tags              = local.tags
}

module "snapshot" {
  source = "./modules/snapshot"

  instance_id      = module.ec2.instance_id
  container_images = var.container_images
  aws_region       = var.aws_region
}
