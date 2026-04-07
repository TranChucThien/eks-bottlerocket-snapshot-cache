# Bottlerocket EBS Snapshot Cache - Kết quả kiểm thử

## Mô tả thử nghiệm

Thử nghiệm đánh giá hiệu quả của việc cache container image vào EBS snapshot trên Bottlerocket instances trong EKS cluster.

[Bottlerocket](https://github.com/bottlerocket-os/bottlerocket) sử dụng 2 volume: OS volume và data volume. Data volume lưu trữ container images. Giải pháp này tạo EBS snapshot từ data volume đã pull sẵn image, sau đó gắn snapshot vào node mới → node khởi động đã có sẵn image mà không cần pull từ registry.

## Kiến trúc giải pháp

![Bottlerocket EBS Snapshot Cache Architecture](pictures/bottlerocket_ebs_snapshot_cache_architecture.svg)

### Quy trình tạo snapshot (tự động qua GitHub Actions)

Workflow `create-snapshot.yml` gồm 2 jobs:

**Job 1 — create-snapshot:**
1. Terraform tạo hạ tầng tạm thời (VPC, Subnet, EC2 Bottlerocket)
2. EC2 Bottlerocket khởi động và pull các container images được chỉ định
3. Tạo EBS snapshot từ data volume (`/dev/xvdb`)
4. Terraform destroy xóa toàn bộ hạ tầng tạm, chỉ giữ lại snapshot

**Job 2 — update-config:**
1. Cập nhật `snapshotID` mới vào `eks-clusterconfig.yaml`
2. Auto commit & push về repo

### Tham số workflow

| Tham số | Mô tả | Mặc định |
|---|---|---|
| `aws_region` | AWS Region | `ap-northeast-1` |
| `environment` | Môi trường (dev/staging/prod) | `dev` |
| `container_images` | Danh sách images cần cache (phân cách bằng dấu phẩy) | `public.ecr.aws/eks-distro/kubernetes/pause:3.2` |
| `instance_type` | Loại EC2 tạm thời | `t2.small` |
| `vpc_cidr` | CIDR cho VPC tạm | `10.0.0.0/16` |

## Kịch bản kiểm thử

Triển khai 2 node group trên cùng một EKS cluster:

| Node Group | Mô tả | EBS Snapshot |
|---|---|---|
| `no-prefetch-mng` | Node thường, không có cache | Không |
| `prefetch-mng` | Node có gắn EBS snapshot chứa image v1 | `snap-008ee0f167abf3f77` |

Deploy cùng một pod lên mỗi node group, đo thời gian pull image qua Kubernetes events.

- **Test 1:** Deploy image `banking-demo:1` (exact match với snapshot) → so sánh thời gian pull giữa 2 node group
- **Test 2:** Deploy image `banking-demo:2` (version mới, chia sẻ layers với v1) → đánh giá hiệu quả cache khi image không khớp chính xác

## Môi trường
- **Cluster:** bottlerocket-cache-cluster
- **Region:** ap-northeast-1
- **Instance type:** t3.medium
- **AMI:** Bottlerocket for EKS
- **Image test:** `chucthien03/banking-demo` (~315MB)
- **Snapshot ID (v1):** `snap-008ee0f167abf3f77`

## Kết quả

### Test 1: Image v1 - Có snapshot cache (exact match)
| Node Group | Image | Pull Time | Event |
|---|---|---|---|
| no-prefetch-mng | `banking-demo:1` | **6.4s** | `Pulling` → `Successfully pulled` |
| prefetch-mng | `banking-demo:1` | **0s** | `Already present on machine` |

> Image match chính xác với snapshot → container khởi động ngay lập tức, không cần pull.

### Test 2: Image v2 - Shared layers với v1 (snapshot cache v1)
| Node Group | Image | Pull Time | Event |
|---|---|---|---|
| no-prefetch-mng | `banking-demo:2` | **7.2s** | `Pulling` → `Successfully pulled` |
| prefetch-mng | `banking-demo:2` | **3.3s** | `Pulling` → `Successfully pulled` |

> Image v2 không có trong snapshot nhưng chia sẻ common layers với v1 → chỉ cần pull các layer thay đổi.

## Phân tích layers

v1 và v2 chia sẻ **9/10 layers**, chỉ khác layer cuối cùng:

```bash
$ docker inspect chucthien03/banking-demo:1 -f '{{json .RootFS.Layers}}' | jq .
$ docker inspect chucthien03/banking-demo:2 -f '{{json .RootFS.Layers}}' | jq .
```

| Layer | v1 | v2 |
|---|---|---|
| 1 | `f2a7f072..` | `f2a7f072..` |
| 2 | `2f61c7a4..` | `2f61c7a4..` |
| 3 | `7d58b159..` | `7d58b159..` |
| 4 | `f953134c..` | `f953134c..` |
| 5 | `87ee703d..` | `87ee703d..` |
| 6 | `ca1f67f2..` | `ca1f67f2..` |
| 7 | `922142ec..` | `922142ec..` |
| 8 | `322972c1..` | `322972c1..` |
| 9 | `5f70bf18..` | `5f70bf18..` |
| 10 | `2800d1f2..` ⚠️ | `3a15b5bf..` ⚠️ |

Khi pull v2 trên node có cache v1:
```bash
$ docker pull chucthien03/banking-demo:2
817807f3c64e: Already exists
a63239663e8a: Already exists
da1ae756ce2b: Already exists
58843afac925: Already exists
8d515e2ee9d6: Already exists
403538b7f05c: Already exists
7a3e37667c8e: Already exists
6f0769704f40: Already exists
4f4fb700ef54: Already exists
c38f0cfa10d9: Pull complete    # ← chỉ layer này cần pull
```

> 9 layers `Already exists` → chỉ pull 1 layer mới, giải thích tại sao prefetch node nhanh hơn ~54%.

## Tổng hợp

| Scenario | no-prefetch | prefetch | Tiết kiệm |
|---|---|---|---|
| Exact match (v1) | 6.4s | **0s** | **100%** |
| Shared layers (v2) | 7.2s | **3.3s** | **~54%** |

## Dockerfile - Tối ưu layers cho snapshot cache

Image `banking-demo` sử dụng multi-stage build với Spring Boot layered jar để tách biệt các layer ít thay đổi (dependencies, JRE) và layer thay đổi thường xuyên (application code):

```dockerfile
FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /app
COPY pom.xml .
RUN mvn dependency:go-offline
COPY src ./src
RUN mvn clean package -DskipTests

FROM eclipse-temurin:17-jre AS extract
WORKDIR /app
COPY --from=build /app/target/*.jar app.jar
RUN java -Djarmode=layertools -jar app.jar extract

FROM eclipse-temurin:17-jre
WORKDIR /app
COPY --from=extract /app/dependencies/ ./
COPY --from=extract /app/spring-boot-loader/ ./
COPY --from=extract /app/snapshot-dependencies/ ./
COPY --from=extract /app/application/ ./
EXPOSE 8080
ENTRYPOINT ["java", "org.springframework.boot.loader.launch.JarLauncher"]
```

Cách Dockerfile này hỗ trợ snapshot cache:

| Layer | Nội dung | Thay đổi khi |
|---|---|---|
| `eclipse-temurin:17-jre` | Base image + JRE | Upgrade JRE |
| `dependencies/` | Maven dependencies | Thêm/sửa dependency |
| `spring-boot-loader/` | Spring Boot loader | Upgrade Spring Boot |
| `snapshot-dependencies/` | SNAPSHOT dependencies | Hiếm khi |
| `application/` | Application code | **Mỗi lần deploy** |

> Khi deploy version mới, chỉ layer `application/` thay đổi → các layer còn lại đã có sẵn trong snapshot cache → giảm đáng kể thời gian pull image.

## Kết luận
- **Exact match:** Snapshot cache loại bỏ hoàn toàn thời gian pull image, container khởi động gần như instant.
- **Shared layers:** Dù image không khớp chính xác, các layer chung từ snapshot vẫn giúp giảm đáng kể thời gian pull (~54%).
- **Dockerfile layered build:** Tách application code thành layer riêng, đảm bảo các layer nặng (JRE, dependencies) được tái sử dụng từ snapshot cache qua các lần deploy.
- Với image lớn hơn (1GB+), hiệu quả của snapshot cache sẽ càng rõ rệt hơn.
