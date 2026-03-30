output "vpc_id" {
  description = "ID of the VPC"
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "List of public subnet IDs"
  value       = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  description = "List of private subnet IDs"
  value       = module.vpc.private_subnet_ids
}

output "nat_gateway_ids" {
  description = "List of NAT Gateway IDs"
  value       = module.vpc.nat_gateway_ids
}

output "ec2_instance_id" {
  description = "ID of the Bottlerocket EC2 instance"
  value       = module.ec2.instance_id
}

output "ec2_private_ip" {
  description = "Private IP of the Bottlerocket EC2 instance"
  value       = module.ec2.instance_private_ip
}

output "snapshot_id" {
  description = "EBS snapshot ID with cached container images"
  value       = module.snapshot.snapshot_id
}
