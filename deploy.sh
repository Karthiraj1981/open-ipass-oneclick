#!/usr/bin/env bash
set -euo pipefail

echo "🌐 Region: ap-northeast-1 (Tokyo)"
REGION="ap-northeast-1"
INSTANCE_TYPE="t3.medium"
TAG_NAME="open-ipass-ec2"
USER_DATA_URL="https://raw.githubusercontent.com/Karthiraj1981/open-ipass-oneclick/main/cloud-init.yaml"

# -------------------------
# 1. CREATE OR REUSE VPC
# -------------------------
echo "🔎 Checking if VPC 'open-ipass-vpc' exists..."
VPC_ID=$(aws ec2 describe-vpcs \
  --region $REGION \
  --filters "Name=tag:Name,Values=open-ipass-vpc" \
  --query "Vpcs[0].VpcId" \
  --output text 2>/dev/null || true)

if [[ "$VPC_ID" == "None" || -z "$VPC_ID" ]]; then
  echo "🧱 Creating VPC..."
  VPC_ID=$(aws ec2 create-vpc \
    --cidr-block 10.0.0.0/16 \
    --region $REGION \
    --query "Vpc.VpcId" \
    --output text)
  aws ec2 create-tags --region $REGION --resources $VPC_ID --tags Key=Name,Value=open-ipass-vpc
else
  echo "✔ VPC exists: $VPC_ID"
fi

# Enable DNS support
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames "{\"Value\":true}" --region $REGION
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support "{\"Value\":true}" --region $REGION


# -----------------------------
# 2. CREATE OR REUSE SUBNET
# -----------------------------
echo "🔎 Checking Subnet..."
SUBNET_ID=$(aws ec2 describe-subnets \
  --region $REGION \
  --filters "Name=tag:Name,Values=open-ipass-subnet" \
  --query "Subnets[0].SubnetId" \
  --output text 2>/dev/null || true)

if [[ "$SUBNET_ID" == "None" || -z "$SUBNET_ID" ]]; then
  echo "🧱 Creating Subnet..."
  SUBNET_ID=$(aws ec2 create-subnet \
    --vpc-id $VPC_ID \
    --cidr-block 10.0.1.0/24 \
    --availability-zone ap-northeast-1a \
    --region $REGION \
    --query "Subnet.SubnetId" \
    --output text)
  aws ec2 create-tags --region $REGION --resources $SUBNET_ID --tags Key=Name,Value=open-ipass-subnet
else
  echo "✔ Subnet exists: $SUBNET_ID"
fi

# Make it public
aws ec2 modify-subnet-attribute \
  --subnet-id $SUBNET_ID \
  --map-public-ip-on-launch \
  --region $REGION


# -----------------------------
# 3. INTERNET GATEWAY + ROUTE
# -----------------------------
echo "🔎 Checking Internet Gateway..."
IGW_ID=$(aws ec2 describe-internet-gateways \
  --region $REGION \
  --filters "Name=tag:Name,Values=open-ipass-igw" \
  --query "InternetGateways[0].InternetGatewayId" \
  --output text 2>/dev/null || true)

if [[ "$IGW_ID" == "None" || -z "$IGW_ID" ]]; then
  echo "🧱 Creating IGW..."
  IGW_ID=$(aws ec2 create-internet-gateway \
    --region $REGION \
    --query "InternetGateway.InternetGatewayId" \
    --output text)
  aws ec2 create-tags --region $REGION --resources $IGW_ID --tags Key=Name,Value=open-ipass-igw
  aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID --region $REGION
else
  echo "✔ IGW exists: $IGW_ID"
fi

echo "🔎 Checking Route Table..."
RT_ID=$(aws ec2 describe-route-tables \
  --region $REGION \
  --filters "Name=tag:Name,Values=open-ipass-rt" \
  --query "RouteTables[0].RouteTableId" \
  --output text 2>/dev/null || true)

if [[ "$RT_ID" == "None" || -z "$RT_ID" ]]; then
  echo "🧱 Creating Route Table..."
  RT_ID=$(aws ec2 create-route-table \
    --vpc-id $VPC_ID \
    --region $REGION \
    --query "RouteTable.RouteTableId" \
    --output text)
  aws ec2 create-tags --region $REGION --resources $RT_ID --tags Key=Name,Value=open-ipass-rt
  aws ec2 create-route --route-table-id $RT_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID --region $REGION
  aws ec2 associate-route-table --route-table-id $RT_ID --subnet-id $SUBNET_ID --region $REGION
else
  echo "✔ Route Table exists: $RT_ID"
fi


# -----------------------------
# 4. SECURITY GROUP
# -----------------------------
echo "🔎 Checking Security Group..."
SG_ID=$(aws ec2 describe-security-groups \
  --region $REGION \
  --filters "Name=group-name,Values=open-ipass-sg" \
  --query "SecurityGroups[0].GroupId" \
  --output text 2>/dev/null || true)

if [[ "$SG_ID" == "None" || -z "$SG_ID" ]]; then
  echo "🧱 Creating Security Group..."
  SG_ID=$(aws ec2 create-security-group \
    --group-name open-ipass-sg \
    --description "Open iPaaS SG" \
    --vpc-id $VPC_ID \
    --region $REGION \
    --output text)

  for port in 22 8080 8161 61616 9092 2181 10105; do
    aws ec2 authorize-security-group-ingress \
      --group-id "$SG_ID" \
      --protocol tcp \
      --port "$port" \
      --cidr 0.0.0.0/0 \
      --region "$REGION" >/dev/null
  done
else
  echo "✔ Security Group exists: $SG_ID"
fi


# -----------------------------
# 5. FIND UBUNTU AMI
# -----------------------------
echo "🔎 Finding latest Ubuntu 22.04 AMI..."
AMI_ID=$(aws ec2 describe-images \
  --region "$REGION" \
  --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
  --query "Images | sort_by(@, &CreationDate) | [-1].ImageId" \
  --output text)

echo "✔ AMI: $AMI_ID"


# -----------------------------
# 6. LAUNCH EC2
# -----------------------------
echo "🚀 Launching EC2 instance..."
INSTANCE_ID=$(aws ec2 run-instances \
  --region "$REGION" \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --subnet-id "$SUBNET_ID" \
  --security-group-ids "$SG_ID" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$TAG_NAME}]" \
  --user-data "$(curl -fsSL "$USER_DATA_URL")" \
  --query "Instances[0].InstanceId" \
  --output text)

echo "⏳ Waiting for EC2..."
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"

PUBLIC_IP=$(aws ec2 describe-instances \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].PublicIpAddress" \
  --output text)

echo "🌍 EC2 Public IP: $PUBLIC_IP"
echo "Services will be up in ~60 seconds."
echo
echo "NiFi:        http://$PUBLIC_IP:8080"
echo "Artemis:     http://$PUBLIC_IP:8161"
echo "Kafka:       $PUBLIC_IP:9092"
echo "ZooKeeper:   $PUBLIC_IP:2181"
echo "EventMesh:   http://$PUBLIC_IP:10105"
echo
echo "🎉 DEPLOYMENT COMPLETE"
