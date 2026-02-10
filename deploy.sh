#!/usr/bin/env bash
set -euo pipefail

# --------------------------------------------
# Open iPaaS One-Click Deployer
# Region: ap-northeast-1 (Tokyo)
# Instance: t3.medium (confirmed)
# By: M365 Copilot (for Karthiraj1981)
# --------------------------------------------

REGION="ap-northeast-1"
INSTANCE_TYPE="t3.medium"
SEC_GROUP_NAME="open-ipass-sg"
TAG_NAME="open-ipass-ec2"
USER_DATA_URL="https://raw.githubusercontent.com/Karthiraj1981/open-ipass-oneclick/main/cloud-init.yaml"

echo "🔎 [1/7] Checking AWS CLI and identity..."
aws sts get-caller-identity >/dev/null

echo "🧱 [2/7] Creating (or reusing) Security Group: ${SEC_GROUP_NAME}"
SG_ID=$(aws ec2 describe-security-groups \
  --region "$REGION" \
  --filters Name=group-name,Values="$SEC_GROUP_NAME" \
  --query 'SecurityGroups[0].GroupId' \
  --output text 2>/dev/null || true)

if [[ "$SG_ID" == "None" || -z "${SG_ID}" ]]; then
  SG_ID=$(aws ec2 create-security-group \
    --group-name "$SEC_GROUP_NAME" \
    --description "Security Group for Open iPaaS (NiFi, Kafka, ZK, Artemis, EventMesh)" \
    --region "$REGION" \
    --output text)
  echo "   Created SG: $SG_ID"

  # Open only required ports (you can tighten sources later)
  # 22 (SSH/EC2 Instance Connect), 8080 (NiFi), 8161 (Artemis console),
  # 61616 (Artemis broker), 9092 (Kafka), 2181 (ZK), 10105 (EventMesh)
  for port in 22 8080 8161 61616 9092 2181 10105; do
    aws ec2 authorize-security-group-ingress \
      --group-id "$SG_ID" \
      --protocol tcp \
      --port "$port" \
      --cidr 0.0.0.0/0 \
      --region "$REGION" >/dev/null
  done
else
  echo "   Reusing SG: $SG_ID"
fi

echo "🖼️ [3/7] Finding latest Ubuntu 22.04 LTS AMI (Canonical) in $REGION..."
AMI_ID=$(aws ec2 describe-images \
  --region "$REGION" \
  --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" "Name=state,Values=available" \
  --query "Images[].{ID:ImageId,Name:Name,CreationDate:CreationDate}" \
  --output json | jq -r 'sort_by(.CreationDate) | last | .ID')

if [[ -z "${AMI_ID}" ]]; then
  echo "❌ Could not resolve Ubuntu AMI. Aborting."
  exit 1
fi
echo "   AMI: $AMI_ID"

echo "🚀 [4/7] Launching EC2 instance (type: ${INSTANCE_TYPE})..."
INSTANCE_ID=$(aws ec2 run-instances \
  --region "$REGION" \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --security-group-ids "$SG_ID" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${TAG_NAME}}]" \
  --user-data "$(curl -fsSL "$USER_DATA_URL")" \
  --query "Instances[0].InstanceId" \
  --output text)

echo "   Instance: $INSTANCE_ID"
echo "⏳ [5/7] Waiting for instance to be running..."
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"

PUBLIC_IP=$(aws ec2 describe-instances \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].PublicIpAddress" \
  --output text)

echo "🌐 [6/7] Instance Public IP: $PUBLIC_IP"
echo "   Waiting ~60s for cloud-init to bootstrap Docker & stack..."
sleep 60

echo
echo "✅ [7/7] Deployment triggered. Services will come up shortly."
echo "----------------------------------------------"
echo "EC2:         http://$PUBLIC_IP"
echo "NiFi:        http://$PUBLIC_IP:8080"
echo "Artemis UI:  http://$PUBLIC_IP:8161  (user: admin / pass: admin)"
echo "Artemis JMS: $PUBLIC_IP:61616"
echo "Kafka:       PLAINTEXT at $PUBLIC_IP:9092"
echo "ZooKeeper:   $PUBLIC_IP:2181"
echo "EventMesh:   http://$PUBLIC_IP:10105"
echo "----------------------------------------------"
echo "Logs (EC2):  sudo journalctl -u docker -f"
echo "Cloud-init:  sudo tail -n 200 /var/log/cloud-init-output.log"
echo
echo "Tip: You can tighten SG sources later to your IP instead of 0.0.0.0/0."
