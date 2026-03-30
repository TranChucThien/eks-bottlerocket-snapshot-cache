data "aws_ssm_parameter" "bottlerocket_ami" {
  count = var.ami_id == "" ? 1 : 0
  name  = var.ami_ssm_parameter
}

data "aws_partition" "current" {}

locals {
  ami_id = var.ami_id != "" ? var.ami_id : data.aws_ssm_parameter.bottlerocket_ami[0].value
}

# IAM Role
resource "aws_iam_role" "this" {
  name = "${var.name}-role"
  path = "/"

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

  tags = merge(var.tags, {
    Name = "${var.name}-role"
  })
}

resource "aws_iam_role_policy_attachment" "ecr_readonly" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "additional" {
  count      = length(var.additional_iam_policies)
  role       = aws_iam_role.this.name
  policy_arn = var.additional_iam_policies[count.index]
}

# Instance Profile
resource "aws_iam_instance_profile" "this" {
  name = "${var.name}-profile"
  path = "/"
  role = aws_iam_role.this.name

  tags = merge(var.tags, {
    Name = "${var.name}-profile"
  })
}

# EC2 Instance
resource "aws_instance" "this" {
  ami                  = local.ami_id
  instance_type        = var.instance_type
  subnet_id            = var.subnet_id
  iam_instance_profile = aws_iam_instance_profile.this.name
  user_data            = base64encode(var.user_data)

  tags = merge(var.tags, {
    Name = var.name
  })
}
