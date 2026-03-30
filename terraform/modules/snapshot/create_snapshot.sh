#!/bin/bash
set -e

INSTANCE_ID="$1"
REGION="$2"
IMAGES="$3"
SNAPSHOT_FILE="$4"

CTR_CMD="apiclient exec admin sheltie ctr -a /run/containerd/containerd.sock -n k8s.io"
export AWS_DEFAULT_REGION="$REGION"
export AWS_PAGER=""

ssm_run() {
  local cmd="$1"
  CMDID=$(aws ssm send-command --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters commands="$cmd" \
    --query "Command.CommandId" --output text)
  aws ssm wait command-executed --command-id "$CMDID" --instance-id "$INSTANCE_ID"
}

# 1. Wait SSM ready
echo "[1/6] Waiting for SSM..."
for i in $(seq 1 60); do
  STATUS=$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
    --query "InstanceInformationList[0].PingStatus" --output text 2>/dev/null)
  [ "$STATUS" = "Online" ] && break
  sleep 10
done
[ "$STATUS" != "Online" ] && echo "SSM timeout" && exit 1
echo "SSM ready!"

# 2. Stop kubelet
echo "[2/6] Stopping kubelet..."
ssm_run "apiclient exec admin sheltie systemctl stop kubelet"

# 3. Cleanup existing images
echo "[3/6] Cleaning up images..."
ssm_run "$CTR_CMD images rm \$($CTR_CMD images ls -q)"

# 4. Pull images
echo "[4/6] Pulling images..."
IFS=',' read -ra IMG_LIST <<< "$IMAGES"
for IMG in "${IMG_LIST[@]}"; do
  ECR_REGION=$(echo "$IMG" | sed -n 's/^[0-9]*\.dkr\.ecr\.\([a-z1-9-]*\)\.amazonaws\.com.*$/\1/p')
  ECRPWD=""
  [ -n "$ECR_REGION" ] && ECRPWD="--u AWS:$(aws ecr get-login-password --region $ECR_REGION)"
  for PLATFORM in amd64 arm64; do
    echo "  $IMG ($PLATFORM)..."
    ssm_run "$CTR_CMD images pull --platform $PLATFORM $IMG $ECRPWD"
  done
done

# 5. Stop instance
echo "[5/6] Stopping instance..."
aws ec2 stop-instances --instance-ids "$INSTANCE_ID" --output text > /dev/null
aws ec2 wait instance-stopped --instance-ids "$INSTANCE_ID"

# 6. Create snapshot
echo "[6/6] Creating snapshot..."
DATA_VOLUME_ID=$(aws ec2 describe-instances --instance-id "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName=='/dev/xvdb'].Ebs.VolumeId" \
  --output text)

SNAPSHOT_ID=$(aws ec2 create-snapshot --volume-id "$DATA_VOLUME_ID" \
  --description "Bottlerocket Data Volume snapshot" \
  --query "SnapshotId" --output text)

aws ec2 wait snapshot-completed --snapshot-ids "$SNAPSHOT_ID"

echo "$SNAPSHOT_ID" > "$SNAPSHOT_FILE"
echo "Done! Snapshot: $SNAPSHOT_ID"
