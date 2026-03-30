# Terraform - Bottlerocket EBS Snapshot Cache

Tạo hạ tầng (VPC + EC2 Bottlerocket) và cache container images vào EBS snapshot để giảm thời gian boot container trên EKS.

## Cấu trúc

```
terraform/
├── main.tf
├── variables.tf
├── outputs.tf
├── terraform.tfvars
├── terraform.tfvars.example
└── modules/
    ├── vpc/         # VPC, Subnet, IGW, NAT Gateway, Route Table
    ├── ec2/         # EC2 Bottlerocket + IAM Role + Instance Profile
    └── snapshot/    # Tự động pull images + tạo EBS snapshot (Cách 2)
```

## Yêu cầu

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.0
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-getting-started.html) đã cấu hình credentials
- Quyền IAM: EC2, VPC, IAM, SSM, EBS, ECR (readonly)

## Cấu hình

```bash
cp terraform.tfvars.example terraform.tfvars
```

Sửa `terraform.tfvars` theo môi trường:

| Biến | Mô tả | Mặc định |
|------|--------|----------|
| `aws_region` | AWS region | - |
| `project_name` | Tên project, dùng làm prefix | - |
| `environment` | `dev` / `staging` / `prod` | - |
| `vpc_cidr` | CIDR cho VPC | - |
| `azs` | Danh sách Availability Zones | - |
| `public_subnet_cidrs` | CIDR cho public subnets | - |
| `private_subnet_cidrs` | CIDR cho private subnets (có thể để `[]`) | - |
| `ami_ssm_parameter` | SSM path cho Bottlerocket AMI | `/aws/service/bottlerocket/aws-k8s-1.24/x86_64/latest/image_id` |
| `instance_type` | EC2 instance type | `t2.small` |
| `container_images` | Danh sách images cần cache, phân cách bằng dấu `,` (dùng cho Cách 2) | `public.ecr.aws/eks-distro/kubernetes/pause:3.2` |
| `tags` | Tags gắn vào tất cả resources | `{}` |

---

## Cách 1: Terraform + chạy thủ công

Terraform chỉ tạo hạ tầng (VPC + EC2). Các bước pull images và tạo snapshot chạy bằng tay.

> Cách này phù hợp khi muốn kiểm soát từng bước, debug, hoặc pull images có logic phức tạp.

### Bước 1: Comment module snapshot trong `main.tf`

```hcl
# module "snapshot" {
#   source = "./modules/snapshot"
#   ...
# }
```

### Bước 2: Deploy hạ tầng

```bash
cd terraform
terraform init
terraform apply
```

### Bước 3: Lấy Instance ID và set biến

```bash
INSTANCE_ID=$(terraform output -raw ec2_instance_id)
AWS_REGION=$(terraform output -raw aws_region 2>/dev/null || grep 'aws_region' terraform.tfvars | cut -d'"' -f2)
export AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_PAGER=""
CTR_CMD="apiclient exec admin sheltie ctr -a /run/containerd/containerd.sock -n k8s.io"
IMAGES="public.ecr.aws/eks-distro/kubernetes/pause:3.2"
```

### Bước 4: Đợi SSM sẵn sàng

```bash
aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
    --query "InstanceInformationList[0].PingStatus"
# Chờ đến khi trả về "Online"
```

### Bước 5: Stop kubelet + xóa images cũ

```bash
# Stop kubelet
CMDID=$(aws ssm send-command --instance-ids $INSTANCE_ID \
    --document-name "AWS-RunShellScript" \
    --parameters commands="apiclient exec admin sheltie systemctl stop kubelet" \
    --query "Command.CommandId" --output text)
aws ssm wait command-executed --command-id "$CMDID" --instance-id $INSTANCE_ID

# Xóa images cũ
CMDID=$(aws ssm send-command --instance-ids $INSTANCE_ID \
    --document-name "AWS-RunShellScript" \
    --parameters commands="$CTR_CMD images rm \$($CTR_CMD images ls -q)" \
    --query "Command.CommandId" --output text)
aws ssm wait command-executed --command-id "$CMDID" --instance-id $INSTANCE_ID
```

### Bước 6: Pull images

```bash
for PLATFORM in amd64 arm64; do
  CMDID=$(aws ssm send-command --instance-ids $INSTANCE_ID \
      --document-name "AWS-RunShellScript" \
      --parameters commands="$CTR_CMD images pull --platform $PLATFORM $IMAGES" \
      --query "Command.CommandId" --output text)
  aws ssm wait command-executed --command-id "$CMDID" --instance-id $INSTANCE_ID
done
```

### Bước 7: Stop EC2 + tạo snapshot

```bash
# Stop EC2
aws ec2 stop-instances --instance-ids $INSTANCE_ID
aws ec2 wait instance-stopped --instance-ids "$INSTANCE_ID"

# Tạo snapshot
DATA_VOLUME_ID=$(aws ec2 describe-instances --instance-id $INSTANCE_ID \
    --query "Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName=='/dev/xvdb'].Ebs.VolumeId" \
    --output text)

SNAPSHOT_ID=$(aws ec2 create-snapshot --volume-id $DATA_VOLUME_ID \
    --description "Bottlerocket Data Volume snapshot" \
    --query "SnapshotId" --output text)

aws ec2 wait snapshot-completed --snapshot-ids "$SNAPSHOT_ID"
echo "Snapshot ID: $SNAPSHOT_ID"
```

### Bước 8: Dọn dẹp

```bash
terraform destroy
```

---

## Cách 2: Terraform tự động hoàn toàn

Terraform tạo hạ tầng + tự động pull images + tạo EBS snapshot trong một lần `apply`.

> Cách này phù hợp cho CI/CD hoặc khi muốn chạy một lệnh duy nhất.

### Bước 1: Đảm bảo module snapshot được bật trong `main.tf`

```hcl
module "snapshot" {
  source = "./modules/snapshot"

  instance_id      = module.ec2.instance_id
  container_images = var.container_images
  aws_region       = var.aws_region
}
```

### Bước 2: Cấu hình images trong `terraform.tfvars`

```hcl
# Một image
container_images = "public.ecr.aws/eks-distro/kubernetes/pause:3.2"

# Nhiều images (phân cách bằng dấu phẩy)
container_images = "image1:tag,image2:tag,image3:tag"
```

### Bước 3: Chạy

```bash
cd terraform
terraform init
terraform apply
```

Terraform sẽ tự động:
1. Tạo VPC + EC2 Bottlerocket
2. Đợi SSM agent online
3. Stop kubelet → xóa images cũ → pull images mới (amd64 + arm64)
4. Stop EC2 → tạo EBS snapshot

### Bước 4: Lấy Snapshot ID

```bash
terraform output snapshot_id
```

### Bước 5: Dọn dẹp

```bash
terraform destroy
```

---

## Outputs

| Output | Mô tả |
|--------|--------|
| `vpc_id` | ID của VPC |
| `public_subnet_ids` | Danh sách public subnet IDs |
| `private_subnet_ids` | Danh sách private subnet IDs |
| `nat_gateway_ids` | Danh sách NAT Gateway IDs |
| `ec2_instance_id` | ID của EC2 Bottlerocket instance |
| `ec2_private_ip` | Private IP của EC2 instance |
| `snapshot_id` | EBS snapshot ID (chỉ có ở Cách 2) |

## Lưu ý

- EC2 được đặt trong **public subnet** để có internet pull images. Nếu muốn dùng private subnet, cần cấu hình `private_subnet_cidrs` và đảm bảo có NAT Gateway.
- Sau khi có `SNAPSHOT_ID`, dùng nó để cấu hình EKS node group với cached data volume.
- Cách 2 dùng `null_resource` + `local-exec`, nên cần AWS CLI trên máy chạy Terraform có quyền SSM và EC2.
