#!/usr/bin/env bash
set -e

REGION="ap-northeast-1"
INSTANCE_TYPE="t3.medium"
KEY_NAME="ipass-dev-key"
TAG_NAME="open-ipass-ec2"
USER_DATA_URL="https://raw.githubusercontent.com/Karthiraj1981/open-ipass-oneclick/main/cloud-init.yaml"

echo "🚀 Minimal deployer starting..."

echo "🔑 Using existing Key Pair: $KEY_NAME"

echo "🛡 Creating NEW security group: open-ipass-sg-minimal"
SG_ID=$(aws ec2 create-security-group \
  --group-name open-ipass-sg-minimal \
  --description "Minimal Security Group" \
  --region $REGION \
  --output text)

echo "🌍 Opening inbound ports on SG..."
aws ec2 authorize-security-group-ingress --region $REGION --group-id $SG_ID --protocol tcp --port 22 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --region $REGION --group-id $SG_ID --protocol tcp --port 8080 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --region $REGION --group-id $SG_ID --protocol tcp --port 8161 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --region $REGION --group-id $SG_ID --protocol tcp --port 61616 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --region $REGION --group-id $SG_ID --protocol tcp --port 9092 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --region $REGION --group-id $SG_ID --protocol tcp --port 2181 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --region $REGION --group-id $SG_ID --protocol tcp --port 10105 --cidr 0.0.0.0/0

echo "🖼 Finding Ubuntu AMI (hardcoded for minimal permissions)"
AMI_ID="ami-0f5a7f590cbf5a3dc"   # Ubuntu 22.04 LTS for ap-northeast-1 (static)

echo "🚀 Launching EC2..."
INSTANCE_ID=$(aws ec2 run-instances \
  --region $REGION \
  --image-id $AMI_ID \
  --instance-type $INSTANCE_TYPE \
  --security-group-ids $SG_ID \
  --key-name $KEY_NAME \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$TAG_NAME}]" \
  --user-data "$(curl -fsSL $USER_DATA_URL)" \
  --query "Instances[0].InstanceId" \
  --output text)

echo "⏳ Waiting for instance..."
aws ec2 wait instance-running --region $REGION --instance-ids $INSTANCE_ID

PUBLIC_IP=$(aws ec2 describe-instances \
  --region $REGION \
  --instance-ids $INSTANCE_ID \
  --query "Reservations[0].Instances[0].PublicIpAddress" \
  --output text)

echo "🌍 EC2 Public IP: $PUBLIC_IP"
echo "   Wait 60–90 seconds for cloud-init to install full stack."

echo "NiFi:        http://$PUBLIC_IP:8080"
echo "Artemis:     http://$PUBLIC_IP:8161"
echo "Kafka:       $PUBLIC_IP:9092"
echo "ZooKeeper:   $PUBLIC_IP:2181"
echo "EventMesh:   http://$PUBLIC_IP:10105"

echo "SSH:"
echo "   ssh -i ~/.ssh/ipass-dev-key.pem ubuntu@$PUBLIC_IP"
