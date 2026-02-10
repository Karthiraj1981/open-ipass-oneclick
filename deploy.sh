#!/usr/bin/env bash
set -euo pipefail

echo "🌐 Region: ap-northeast-1 (Tokyo)"
REGION="ap-northeast-1"
INSTANCE_TYPE="t3.medium"
TAG_NAME="open-ipass-ec2"
USER_DATA_URL="https://raw.githubusercontent.com/Karthiraj1981/open-ipass-oneclick/main/cloud-init.yaml"

KEY_NAME="ipass-dev-key"
KEY_PATH="$HOME/.ssh/${KEY_NAME}.pem"

# -------------------------
# 0. PREPARE SSH KEY PAIR
# -------------------------
echo "🔑 Checking EC2 key pair '$KEY_NAME' in $REGION ..."
EXISTING_KEY=$(aws ec2 describe-key-pairs \
  --region "$REGION" \
  --key-names "$KEY_NAME" \
  --query 'KeyPairs[0].KeyName' \
  --output text 2>/dev/null || true)

if [[ -z "$EXISTING_KEY" || "$EXISTING_KEY" == "None" ]]; then
  echo "🧾 Creating new key pair '$KEY_NAME' and saving to $KEY_PATH ..."
  mkdir -p "$HOME/.ssh"
  aws ec2 create-key-pair \
    --region "$REGION" \
    --key-name "$KEY_NAME" \
    --key-type rsa \
    --key-format pem \
    --query 'KeyMaterial' \
    --output text > "$KEY_PATH"
  chmod 400 "$KEY_PATH"
  echo "   ✔ Key saved (permissions set to 400)."
else
  echo "✔ Key pair exists in AWS: $EXISTING_KEY"
  if [[ ! -f "$KEY_PATH" ]]; then
    cat <<EOF
⚠ Key pair exists in AWS but PEM is not present at $KEY_PATH.
   AWS only returns private key ONCE at creation time.
   You have 3 options:
   1) Use EC2 Instance Connect (no key needed) from the EC2 console.
   2) Delete the existing key pair and re-run to create a fresh one:
        aws ec2 delete-key-pair --region $REGION --key-name $KEY_NAME
   3) Change KEY_NAME in this script to a new name and re-run.
EOF
  else
    echo "✔ Local PEM exists at $KEY_PATH"
    chmod 400 "$KEY_PATH" || true
  fi
fi

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

# Enable DNS
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames "{\"Value\":true}" --region $REGION
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support "{\"Value\":true}" --region $REGION

# -----------------------------
# 2. CREATE OR REUSE SUBNET
# -----------------------------
echo "🔎 Checking Subnet 'open-ipass-subnet'..."
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
echo "🔎 Checking Internet Gateway 'open-ipass-igw'..."
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

echo "🔎 Checking Route Table 'open-ipass-rt'..."
RT_ID=$(aws ec2 describe-route-tables \
  --region $REGION \
  --filters "Name=tag:Name,Values=open-ipass-rt" \
  --query "RouteTables[0].RouteTableId" \
  --output text 2>/dev/null || true)

if [[ "$RT_ID" == "None" || -z "$RT_ID" ]]; then
  echo "🧱 Creating Route Table and default route..."
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
echo "🔎 Checking Security Group 'open-ipass-sg'..."
SG_ID=$(aws ec2 describe-security-groups \
  --region $REGION \
  --filters "Name=group-name,Values=open-ipass-sg" "Name=vpc-id,Values=$VPC_ID" \
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

  # Allow required ports (for POC; tighten later)
  for port in 22 8080 8161 61616 9092 2181 10105; do
    aws ec2 authorize-security-group-ingress \
      --group-id "$SG_ID" \
      --protocol tcp \
      --port "$port" \
      --cidr 0.0.0.0/0 \
      --region "$REGION" >/dev/null
  done

  # Optional: restrict SSH to your current IP (uncomment to use)
  # MYIP=$(curl -s https://checkip.amazonaws.com || echo "0.0.0.0")
  # aws ec2 revoke-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 22 --cidr 0.0.0.0/0 --region "$REGION" || true
  # aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 22 --cidr "${MYIP}/32" --region "$REGION" || true
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
echo "🚀 Launching EC2 instance with key '$KEY_NAME'..."
INSTANCE_ID=$(aws ec2 run-instances \
  --region "$REGION" \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --subnet-id "$SUBNET_ID" \
  --security-group-ids "$SG_ID" \
  --key-name "$KEY_NAME" \
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
echo "   Waiting ~60-90s for cloud-init to bootstrap Docker & stack..."
sleep 75

echo
echo "✅ Deployment triggered. Services will come up shortly."
echo "----------------------------------------------"
echo "EC2:         http://$PUBLIC_IP"
echo "NiFi:        http://$PUBLIC_IP:8080"
echo "Artemis UI:  http://$PUBLIC_IP:8161  (user: admin / pass: admin)"
echo "Artemis JMS: $PUBLIC_IP:61616"
echo "Kafka:       PLAINTEXT at $PUBLIC_IP:9092"
echo "ZooKeeper:   $PUBLIC_IP:2181"
echo "EventMesh:   http://$PUBLIC_IP:10105"
echo "----------------------------------------------"
echo "SSH (Linux/Mac/CloudShell):"
echo "   ssh -i \"$KEY_PATH\" ubuntu@$PUBLIC_IP"
echo
echo "Logs on EC2:"
echo "   sudo tail -n 200 /var/log/cloud-init-output.log"
echo "   docker ps"
echo
echo "Tip: You can tighten SG sources later to your IP instead of 0.0.0.0/0."
