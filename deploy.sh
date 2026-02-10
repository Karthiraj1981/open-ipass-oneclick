#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# SETTINGS
###############################################################################
REGION="ap-northeast-1"
INSTANCE_TYPE="t3.medium"
KEY_NAME="ipass-dev-key"
TAG_NAME="open-ipass-ec2"
USER_DATA_URL="https://raw.githubusercontent.com/Karthiraj1981/open-ipass-oneclick/main/cloud-init.yaml"

echo "🌏 Region: $REGION"
KEY_PATH="$HOME/.ssh/${KEY_NAME}.pem"

###############################################################################
# 0. ENSURE KEY PAIR EXISTS (REUSE OR CREATE)
###############################################################################
echo "🔑 Checking EC2 key pair '$KEY_NAME'..."
EXISTING_KEY=$(aws ec2 describe-key-pairs \
  --region "$REGION" \
  --key-names "$KEY_NAME" \
  --query 'KeyPairs[0].KeyName' \
  --output text 2>/dev/null || true)

if [[ -z "$EXISTING_KEY" || "$EXISTING_KEY" == "None" ]]; then
  echo "🆕 Creating new EC2 key pair..."
  mkdir -p "$HOME/.ssh"
  aws ec2 create-key-pair \
    --region "$REGION" \
    --key-name "$KEY_NAME" \
    --query 'KeyMaterial' \
    --output text > "$KEY_PATH"
  chmod 400 "$KEY_PATH"
else
  echo "✔ Key exists in AWS."
  if [[ ! -f "$KEY_PATH" ]]; then
    echo "⚠ PEM missing locally — recreate key or change KEY_NAME."
    exit 1
  fi
fi

###############################################################################
# 1. REUSE OR CREATE VPC
###############################################################################
echo "🔍 Checking VPC 'open-ipass-vpc'..."
VPC_ID=$(aws ec2 describe-vpcs \
  --region "$REGION" \
  --filters "Name=tag:Name,Values=open-ipass-vpc" \
  --query 'Vpcs[0].VpcId' \
  --output text 2>/dev/null || true)

if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
  echo "🧱 Creating VPC..."
  VPC_ID=$(aws ec2 create-vpc \
    --cidr-block 10.0.0.0/16 \
    --region "$REGION" \
    --query 'Vpc.VpcId' \
    --output text)
  aws ec2 create-tags --region "$REGION" --resources "$VPC_ID" --tags Key=Name,Value=open-ipass-vpc
else
  echo "✔ Reusing VPC: $VPC_ID"
fi

aws ec2 modify-vpc-attribute --region "$REGION" --vpc-id "$VPC_ID" --enable-dns-support "{\"Value\":true}"
aws ec2 modify-vpc-attribute --region "$REGION" --vpc-id "$VPC_ID" --enable-dns-hostnames "{\"Value\":true}"

###############################################################################
# 2. REUSE OR CREATE SUBNET
###############################################################################
echo "🔍 Checking Subnet 'open-ipass-subnet'..."
SUBNET_ID=$(aws ec2 describe-subnets \
  --region "$REGION" \
  --filters "Name=tag:Name,Values=open-ipass-subnet" \
  --query 'Subnets[0].SubnetId' \
  --output text 2>/dev/null || true)

if [[ -z "$SUBNET_ID" || "$SUBNET_ID" == "None" ]]; then
  echo "📡 Creating Subnet..."
  SUBNET_ID=$(aws ec2 create-subnet \
    --vpc-id "$VPC_ID" \
    --cidr-block 10.0.1.0/24 \
    --availability-zone "${REGION}a" \
    --region "$REGION" \
    --query 'Subnet.SubnetId' \
    --output text)
  aws ec2 create-tags --region "$REGION" --resources "$SUBNET_ID" --tags Key=Name,Value=open-ipass-subnet
else
  echo "✔ Reusing Subnet: $SUBNET_ID"
fi

aws ec2 modify-subnet-attribute --region "$REGION" --subnet-id "$SUBNET_ID" --map-public-ip-on-launch

###############################################################################
# 3. REUSE OR CREATE IGW + ROUTE TABLE
###############################################################################
echo "🔍 Checking Internet Gateway 'open-ipass-igw'..."
IGW_ID=$(aws ec2 describe-internet-gateways \
  --region "$REGION" \
  --filters "Name=tag:Name,Values=open-ipass-igw" \
  --query 'InternetGateways[0].InternetGatewayId' \
  --output text 2>/dev/null || true)

if [[ -z "$IGW_ID" || "$IGW_ID" == "None" ]]; then
  echo "🌍 Creating Internet Gateway..."
  IGW_ID=$(aws ec2 create-internet-gateway \
    --region "$REGION" \
    --query 'InternetGateway.InternetGatewayId' \
    --output text)
  aws ec2 create-tags --region "$REGION" --resources "$IGW_ID" --tags Key=Name,Value=open-ipass-igw
  aws ec2 attach-internet-gateway --region "$REGION" --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
else
  echo "✔ Reusing IGW: $IGW_ID"
fi

echo "🔍 Checking Route Table 'open-ipass-rt'..."
RT_ID=$(aws ec2 describe-route-tables \
  --region "$REGION" \
  --filters "Name=tag:Name,Values=open-ipass-rt" \
  --query 'RouteTables[0].RouteTableId' \
  --output text 2>/dev/null || true)

if [[ -z "$RT_ID" || "$RT_ID" == "None" ]]; then
  echo "🛣 Creating Route Table..."
  RT_ID=$(aws ec2 create-route-table \
    --region "$REGION" \
    --vpc-id "$VPC_ID" \
    --query 'RouteTable.RouteTableId' \
    --output text)
  aws ec2 create-tags --region "$REGION" --resources "$RT_ID" --tags Key=Name,Value=open-ipass-rt
  aws ec2 create-route --region "$REGION" --route-table-id "$RT_ID" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID"
  aws ec2 associate-route-table --region "$REGION" --route-table-id "$RT_ID" --subnet-id "$SUBNET_ID"
else
  echo "✔ Reusing Route Table: $RT_ID"
fi

###############################################################################
# 4. SECURITY GROUP (REUSE OR CREATE)
###############################################################################
echo "🔍 Checking Security Group 'open-ipass-sg'..."
SG_ID=$(aws ec2 describe-security-groups \
  --region "$REGION" \
  --filters "Name=group-name,Values=open-ipass-sg" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' \
  --output text 2>/dev/null || true)

if [[ -z "$SG_ID" || "$SG_ID" == "None" ]]; then
  echo "🧱 Creating Security Group..."
  SG_ID=$(aws ec2 create-security-group \
    --group-name open-ipass-sg \
    --description "Open iPaaS SG" \
    --vpc-id "$VPC_ID" \
    --region "$REGION" \
    --output text)

  for PORT in 22 8080 8161 61616 9092 10105 10000 10205; do
    aws ec2 authorize-security-group-ingress \
      --group-id "$SG_ID" \
      --protocol tcp \
      --port "$PORT" \
      --cidr 0.0.0.0/0 \
      --region "$REGION"
  done
else
  echo "✔ Reusing Security Group: $SG_ID"
fi

###############################################################################
# 5. LATEST UBUNTU AMI
###############################################################################
echo "🔍 Finding latest Ubuntu 22.04 AMI..."
AMI_ID=$(aws ec2 describe-images \
  --region "$REGION" \
  --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
  --query "Images | sort_by(@, &CreationDate)[-1].ImageId" \
  --output text)

echo "✔ AMI: $AMI_ID"

###############################################################################
# 6. LAUNCH EC2 INSTANCE
###############################################################################
echo "🚀 Launching EC2..."
INSTANCE_ID=$(aws ec2 run-instances \
  --region "$REGION" \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --subnet-id "$SUBNET_ID" \
  --security-group-ids "$SG_ID" \
  --key-name "$KEY_NAME" \
  --associate-public-ip-address \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$TAG_NAME}]" \
  --user-data "$(curl -fsSL "$USER_DATA_URL")" \
  --query 'Instances[0].InstanceId' \
  --output text)

echo "⏳ Waiting for EC2 to start..."
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"

PUBLIC_IP=$(aws ec2 describe-instances \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

echo "🌍 Public IP: $PUBLIC_IP"
echo "⏳ Waiting 75 seconds for cloud-init..."
sleep 75

###############################################################################
# FINAL OUTPUT
###############################################################################
echo ""
echo "🎉 Deployment Complete!"
echo "---------------------------------------------"
echo "NiFi UI:          http://$PUBLIC_IP:8080"
echo "Artemis Console:  http://$PUBLIC_IP:8161"
echo "Kafka (PLAINTEXT): $PUBLIC_IP:9092"
echo "EventMesh:        http://$PUBLIC_IP:10105"
echo "SSH: ssh -i $KEY_PATH ubuntu@$PUBLIC_IP"
echo "---------------------------------------------"
echo "Logs:"
echo "sudo tail -n 200 /var/log/cloud-init-output.log"
echo "docker ps"
