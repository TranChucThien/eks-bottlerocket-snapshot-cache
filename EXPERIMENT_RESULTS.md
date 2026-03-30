# Kết quả thử nghiệm Bottlerocket Image Caching

## Mô tả thử nghiệm

### Mục đích
Giảm thời gian khởi động container trên Amazon EKS bằng cách sử dụng tính năng data volume của Bottlerocket để prefetch container images.

### Vấn đề cần giải quyết
Việc pull và extract các images có kích thước lớn (>1 GiB) từ Amazon ECR có thể mất vài phút -> ảnh hưởng đến hiệu suất 

### Giải pháp
Sử dụng Bottlerocket OS với kiến trúc 2 volumes (OS volume và data volume) để:
1. Tạo EBS snapshot của data volume đã chứa sẵn container images
2. Sử dụng snapshot này khi tạo worker node mới
3. Container images đã có sẵn trên local disk, không cần pull từ registry

### Kiến trúc Bottlerocket
- **OS Volume** (`/dev/xvda`): Lưu trữ OS data và boot images
- **Data Volume** (`/dev/xvdb`): Lưu trữ container metadata, images và ephemeral volumes

### Quy trình thử nghiệm

**Bước 1: Tạo EBS Snapshot**
1. Khởi động EC2 instance với Bottlerocket AMI
2. Pull các container images cần cache
3. Tạo EBS snapshot của data volume
4. Xóa EC2 instance

**Bước 2: Tạo EKS Cluster**
1. Tạo 2 managed node groups:
   - `no-prefetch-mng`: Không sử dụng snapshot (baseline)
   - `prefetch-mng`: Sử dụng snapshot với images đã prefetch
2. Cả 2 node groups đều sử dụng Bottlerocket AMI

**Bước 3: Deploy và đo lường**
1. Deploy 2 deployments với cùng container image
2. Mỗi deployment được schedule vào node group tương ứng
3. Thu thập pod events để đo thời gian khởi động

### Lưu ý quan trọng
- Image pull policy phải là `IfNotPresent` (default) để prefetching hoạt động
- Nếu set policy là `Always`, container sẽ luôn pull image từ registry

## Thông tin cấu hình

- **Cluster Name**: bottlerocket-cache-cluster
- **Region**: ap-northeast-1
- **Kubernetes Version**: 1.33
- **Instance Type**: t3.medium
- **EBS Snapshot ID**: snap-0ecdb6b655c5606a5
- **Container Image**: public.ecr.aws/kubeflow-on-aws/notebook-servers/jupyter-pytorch:1.12.1-cpu-py38-ubuntu20.04-ec2-v1.2
- **Image Size**: 4.93 GB

## Kết quả đo lường

### Node Group: no-prefetch-mng (Không có prefetch)

**Pod Name**: `inflate-no-prefetch-7cd75c6886-4kp99`  
**Node**: `ip-192-168-171-150.ap-northeast-1.compute.internal`

| Metric | Thời gian | Ghi chú |
|--------|-----------|----------|
| Pod Scheduled | N/A | Successfully assigned to node |
| Image Pulling Started | 2026-03-12T09:21:06Z | Bắt đầu pull image |
| Image Pulled Successfully | 2026-03-12T09:22:18Z | Pull thành công sau 1m11.868s |
| Container Created | 2026-03-12T09:22:18Z | Tạo container |
| Container Started | 2026-03-12T09:22:18Z | Container đã chạy |
| **Tổng thời gian khởi động** | **~72 giây** | **Từ lúc pull đến khi start** |

**Image Size**: 1,681,892,456 bytes (~1.57 GB)

### Node Group: prefetch-mng (Có prefetch)

**Pod Name**: `inflate-prefetch-5d5c958fcf-l8wwb`  
**Node**: `ip-192-168-116-200.ap-northeast-1.compute.internal`

| Metric | Thời gian | Ghi chú |
|--------|-----------|----------|
| Pod Scheduled | N/A | Successfully assigned to node |
| Image Already Present | 2026-03-12T09:21:06Z | Image đã có sẵn trên node |
| Container Created | 2026-03-12T09:21:06Z | Tạo container ngay lập tức |
| Container Started | 2026-03-12T09:21:07Z | Container đã chạy |
| **Tổng thời gian khởi động** | **~1 giây** | **Không cần pull image** |

## So sánh hiệu suất

| Tiêu chí | No-prefetch | Prefetch | Cải thiện |
|----------|-------------|----------|-----------|
| Thời gian khởi động | 72 giây | 1 giây | 98.6% |
| Thời gian pull image | 71.868 giây | 0 giây | 100% |
| Image size | 1.57 GB | 1.57 GB | - |

## Lệnh kiểm tra đã sử dụng

```bash
# Kiểm tra pod no-prefetch
NO_PREFETCH_POD=$(kubectl get pod -l app=inflate-no-prefetch -o jsonpath="{.items[0].metadata.name}")
kubectl get events -o custom-columns=Time:.lastTimestamp,From:.source.component,Type:.type,Reason:.reason,Message:.message --field-selector involvedObject.name=$NO_PREFETCH_POD,involvedObject.kind=Pod

# Kiểm tra pod prefetch
PREFETCH_POD=$(kubectl get pod -l app=inflate-prefetch -o jsonpath="{.items[0].metadata.name}")
kubectl get events -o custom-columns=Time:.lastTimestamp,From:.source.component,Type:.type,Reason:.reason,Message:.message --field-selector involvedObject.name=$PREFETCH_POD,involvedObject.kind=Pod
```

## Chi tiết Pod Events

### No-prefetch Pod Events
```
Time                   From      Type     Reason      Message
<nil>                  <none>    Normal   Scheduled   Successfully assigned default/inflate-no-prefetch-7cd75c6886-4kp99 to ip-192-168-171-150.ap-northeast-1.compute.internal
2026-03-12T09:21:06Z   kubelet   Normal   Pulling     Pulling image "public.ecr.aws/kubeflow-on-aws/notebook-servers/jupyter-pytorch:1.12.1-cpu-py38-ubuntu20.04-ec2-v1.2"
2026-03-12T09:22:18Z   kubelet   Normal   Pulled      Successfully pulled image "public.ecr.aws/kubeflow-on-aws/notebook-servers/jupyter-pytorch:1.12.1-cpu-py38-ubuntu20.04-ec2-v1.2" in 1m11.868s (1m11.868s including waiting). Image size: 1681892456 bytes.
2026-03-12T09:22:18Z   kubelet   Normal   Created     Created container: inflate-amazon-linux
2026-03-12T09:22:18Z   kubelet   Normal   Started     Started container inflate-amazon-linux
```

### Prefetch Pod Events
```
Time                   From      Type     Reason      Message
<nil>                  <none>    Normal   Scheduled   Successfully assigned default/inflate-prefetch-5d5c958fcf-l8wwb to ip-192-168-116-200.ap-northeast-1.compute.internal
2026-03-12T09:21:06Z   kubelet   Normal   Pulled      Container image "public.ecr.aws/kubeflow-on-aws/notebook-servers/jupyter-pytorch:1.12.1-cpu-py38-ubuntu20.04-ec2-v1.2" already present on machine
2026-03-12T09:21:06Z   kubelet   Normal   Created     Created container: inflate-bottlerocket
2026-03-12T09:21:07Z   kubelet   Normal   Started     Started container inflate-bottlerocket
```

## Kết luận

### Kết quả chính
- **Giảm 98.6% thời gian khởi động container**: Từ 72 giây xuống còn 1 giây
- **Loại bỏ hoàn toàn thời gian pull image**: Image đã có sẵn trên node nhờ EBS snapshot
- **Cải thiện đáng kể cho large images**: Với image size 1.57 GB, việc prefetch mang lại lợi ích rõ rệt

### Ưu điểm của giải pháp
1. **Tốc độ**: Container khởi động gần như ngay lập tức
2. **Hiệu quả**: Không tốn băng thông network để pull image
3. **Khả năng mở rộng**: Khi scale up nodes, images đã sẵn sàng
4. **Phù hợp cho**: ML/AI workloads với large container images

### Lưu ý khi triển khai
- Cần cập nhật EBS snapshot khi có image mới
- Chi phí lưu trữ EBS snapshot
- Image pull policy phải là `IfNotPresent` (default)

## Đề xuất triển khai Production

### 1. Tự động hóa với CI/CD Pipeline

**Yêu cầu**: Tự động tạo EBS snapshot sau khi build container image mới

**Quy trình đề xuất**:
```
Build Image → Push to ECR → Create EBS Snapshot → Update Karpenter/NodeTemplate → Deploy
```

**Ví dụ GitHub Actions**:
```yaml
jobs:
  build_image:
    runs-on: ubuntu-latest
    steps:
      - name: Build and Push Image
        run: |
          docker build -t $ECR_REPO:$TAG .
          docker push $ECR_REPO:$TAG
  
  build_ebs_snapshot:
    needs: build_image
    runs-on: ubuntu-latest
    steps:
      - name: Create EBS Snapshot
        run: |
          ./snapshot.sh -r $AWS_REGION $ECR_REPO:$TAG
          echo "SNAPSHOT_ID=$SNAPSHOT_ID" >> $GITHUB_OUTPUT
      
      - name: Update Karpenter NodeTemplate
        run: |
          sed -i "s/snapshotID: .*/snapshotID: $SNAPSHOT_ID/" karpenter-nodetemplate.yaml
          git add karpenter-nodetemplate.yaml
          git commit -m "Update snapshot ID: $SNAPSHOT_ID"
          git push
```

### 2. Tích hợp với Karpenter và Cluster Autoscaler

#### 2.1. Karpenter (EC2NodeClass)

**Cấu hình snapshot trong EC2NodeClass**:
```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: ml-bottlerocket-nodeclass
spec:
  amiFamily: Bottlerocket
  role: "KarpenterNodeRole-${CLUSTER_NAME}"
  
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: "${CLUSTER_NAME}"
  
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: "${CLUSTER_NAME}"
  
  # Block device với EBS snapshot
  blockDeviceMappings:
    - deviceName: /dev/xvda  # OS Volume
      ebs:
        volumeSize: 10Gi
        volumeType: gp3
    - deviceName: /dev/xvdb  # Data Volume với prefetched images
      ebs:
        volumeSize: 100Gi
        volumeType: gp3
        snapshotID: snap-0ecdb6b655c5606a5  # ← Snapshot ID được auto-update bởi CI/CD
```

#### 2.2. Cluster Autoscaler

**Option 1: Launch Template**
```json
{
  "BlockDeviceMappings": [
    {
      "DeviceName": "/dev/xvda",
      "Ebs": {
        "VolumeSize": 10,
        "VolumeType": "gp3"
      }
    },
    {
      "DeviceName": "/dev/xvdb",
      "Ebs": {
        "VolumeSize": 100,
        "VolumeType": "gp3",
        "SnapshotId": "snap-0ecdb6b655c5606a5"
      }
    }
  ]
}
```

**Option 2: eksctl Managed Node Group**
```yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_REGION}

managedNodeGroups:
  - name: ml-prefetch-mng
    instanceType: m5.2xlarge
    amiFamily: Bottlerocket
    
    # Cấu hình volumes với snapshot
    additionalVolumes:
      - volumeName: '/dev/xvda'
        volumeSize: 10
      - volumeName: '/dev/xvdb'
        volumeSize: 100
        snapshotID: snap-0ecdb6b655c5606a5  # ← Snapshot với prefetched images
```

### 3. Chiến lược Multi-Snapshot cho các Workload khác nhau

**Tối ưu hóa**: Tạo nhiều snapshot cho các loại workload khác nhau

| Workload Type | Images | Snapshot ID | Node Template |
|---------------|--------|-------------|---------------|
| ML Training | PyTorch, TensorFlow | snap-ml-xxx | ml-nodetemplate |
| Data Analytics | Spark, Jupyter | snap-analytics-xxx | analytics-nodetemplate |
| AI Inference | ONNX, TensorRT | snap-inference-xxx | inference-nodetemplate |
| General | Base images | snap-general-xxx | general-nodetemplate |

**Ví dụ cấu hình**:
```yaml
# ML Training NodeTemplate
apiVersion: karpenter.k8s.aws/v1alpha1
kind: AWSNodeTemplate
metadata:
  name: ml-training-template
spec:
  amiFamily: Bottlerocket
  blockDeviceMappings:
    - deviceName: /dev/xvdb
      ebs:
        volumeSize: 200Gi
        snapshotID: snap-ml-training-xxx
---
# Data Analytics NodeTemplate
apiVersion: karpenter.k8s.aws/v1alpha1
kind: AWSNodeTemplate
metadata:
  name: analytics-template
spec:
  amiFamily: Bottlerocket
  blockDeviceMappings:
    - deviceName: /dev/xvdb
      ebs:
        volumeSize: 150Gi
        snapshotID: snap-analytics-xxx
```

### 4. Quản lý Snapshot Lifecycle

**Best Practices**:
- Tag snapshots với version và timestamp
- Tự động xóa snapshots cũ (giữ lại 3-5 versions gần nhất)
- Monitor snapshot costs

**Script tự động cleanup**:
```bash
#!/bin/bash
# Giữ lại 5 snapshots mới nhất, xóa các snapshots cũ
SNAPSHOTS=$(aws ec2 describe-snapshots \
  --owner-ids self \
  --filters "Name=tag:Type,Values=bottlerocket-cache" \
  --query 'Snapshots | sort_by(@, &StartTime) | [:-5].SnapshotId' \
  --output text)

for snap in $SNAPSHOTS; do
  echo "Deleting old snapshot: $snap"
  aws ec2 delete-snapshot --snapshot-id $snap
done
```

### 5. Monitoring và Validation

**Metrics cần theo dõi**:
- Pod startup time (so sánh với/không có prefetch)
- Snapshot creation time
- Snapshot storage costs
- Node provisioning time

**Validation checklist**:
- [ ] Image pull policy = `IfNotPresent`
- [ ] Snapshot ID được update trong NodeTemplate
- [ ] Karpenter/CA có thể tạo nodes với snapshot
- [ ] Pods schedule đúng node group
- [ ] Container startup time < 5 seconds

### 6. Khi nào nên sử dụng giải pháp này?

**Phù hợp**:
- ✅ Container images > 1 GB
- ✅ Workloads cần scale nhanh (ML training, batch processing)
- ✅ Cluster thường xuyên scale up/down
- ✅ Sử dụng Spot instances (cần khởi động nhanh)
- ✅ Multi-tenant clusters với nhiều loại workload

**Không phù hợp**:
- ❌ Images nhỏ (< 500 MB)
- ❌ Cluster ít scale
- ❌ Images thay đổi liên tục (nhiều lần/ngày)
- ❌ Không có CI/CD pipeline

## Tài liệu tham khảo

- [Bottlerocket GitHub](https://github.com/bottlerocket-os/bottlerocket)
- [AWS Blog: Reduce container startup time on Amazon EKS](https://aws.amazon.com/blogs/containers/reduce-container-startup-time-on-amazon-eks-with-bottlerocket-data-volume/)
- [Karpenter Documentation](https://karpenter.sh/)
- [Sample Automation Script](https://github.com/aws-samples/containers-blog-maelstrom/tree/main/bottlerocket-images-cache)

## Ghi chú

- Ngày thực hiện: 2026-03-12
- Region: ap-northeast-1 (Tokyo)
- Cluster: bottlerocket-cache-cluster
- Kubernetes Version: 1.33
- Instance Type: t3.medium
- Autoscaler: Karpenter (recommended) hoặc Cluster Autoscaler
