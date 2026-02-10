#!/usr/bin/env bash
set -e

REGION="ap-northeast-1"
INSTANCE_TYPE="t3.medium"
KEY_NAME="ipass-dev-key"
TAG_NAME="open-ipass-ec2"
USER_DATA_URL="https://raw.githubusercontent.com/Karthiraj1981/open-ipass-oneclick/main/cloud-init.yaml"

echo "🚀 Starting Minimal VPC + EC2 Deploy..."
echo "🌏 Region: $REGION"
echo "🔑 Using Key Pair: $KEY_NAME"
echo ""

# --------------------------------------------
# 1. CREATE MINIMAL VPC
# --------------------------------------------
echo "🧱 Creating minimal VPC..."
VPC_ID=$(aws ec2 create-vpc \
  --region $REGION \
  --cidr-block 10.0.0.0/16 \
  --query 'Vpc.VpcId' \
  --output text)

aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames "{\"Value\":true}" --region $REGION
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support "{\"Value\":true}" --region $REGION

echo "   ✔ VPC: $VPC_ID"

# --------------------------------------------
# 2. CREATE SUBNET
# --------------------------------------------
echo "📡 Creating Subnet..."
SUBNET_ID=$(aws ec2 create-subnet \
  --region $REGION \
  --vpc-id "$VPC_ID" \
  --cidr-block 10.0.1.0/24 \
  --availability-zone ap-northeast-1a \
  --query 'Subnet.SubnetId' \
  --output text)

aws ec2 modify-subnet-attribute --subnet-id "$SUBNET_ID" --map-public-ip-on-launch --region $REGION
echo "   ✔ Subnet: $SUBNET_ID"

# --------------------------------------------
# 3. INTERNET GATEWAY + ROUTE
# --------------------------------------------
echo "🌍 Creating Internet Gateway..."
IGW_ID=$(aws ec2 create-internet-gateway \
  --region $REGION \
  --query 'InternetGateway.InternetGatewayId' \
  --output text)

aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region $REGION
echo "   ✔ IGW: $IGW_ID"

echo "🛣 Creating Route Table..."
RT_ID=$(aws ec2 create-route-table \
  --region $REGION \
  --vpc-id "$VPC_ID" \
  --query 'RouteTable.RouteTableId' \
  --output text)

aws ec2 create-route \
  --region $REGION \
  --route-table-id "$RT_ID" \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id "$IGW_ID" >/dev/null

aws ec2 associate-route-table \
  --region $REGION \
  --route-table-id "$RT_ID" \
  --subnet-id "$SUBNET_ID" >/dev/null

echo "   ✔ Route Table: $RT_ID"

# --------------------------------------------
# 4. SECURITY GROUP (new every time)
# --------------------------------------------
echo "🛡 Creating new SG..."
SG_NAME="ipass-sg-$(date +%s)"
SG_ID=$(aws ec2 create-security-group \
  --region $REGION \
  --group-name "$SG_NAME" \
  --description "iPaaS SG" \
  --vpc-id "$VPC_ID" \
  --output text)

echo "   ✔ SG: $SG_ID"

echo "🔓 Opening required ports..."
REQUIRED_PORTS=(22 8080 8161 61616 9092 2181 10105)
for PORT in "${REQUIRED_PORTS[@]}"; do
  aws ec2 authorize-security-group-ingress \
    --region $REGION \
    --group-id "$SG_ID" \
    --protocol tcp \
    --port "$PORT" \
    --cidr 0.0.0.0/0 >/dev/null
done
echo "   ✔ All ports opened"


# --------------------------------------------
# 5. LAUNCH EC2
# --------------------------------------------
echo "🚀 Launching EC2..."

AMI_ID="ami-0f5a7f590cbf5a3dc"   # Ubuntu 22.04 for ap-northeast-1

INSTANCE_ID=$(aws ec2 run-instances \
  --region $REGION \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --subnet-id "$SUBNET_ID" \
  --security-group-ids "$SG_ID" \
  --key-name "$KEY_NAME" \
  --associate-public-ip-address \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$TAG_NAME}]" \
  --user-data "$(curl -fsSL $USER_DATA_URL)" \
  --query 'Instances[0].InstanceId' \
  --output text)

echo "   ✔ Instance: $INSTANCE_ID"
echo "⏳ Waiting for EC2 to start..."

aws ec2 wait instance-running --region $REGION --instance-ids "$INSTANCE_ID"

PUBLIC_IP=$(aws ec2 describe-instances \
  --region $REGION \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

echo "🌍 Public IP: $PUBLIC_IP"
echo "⏳ Waiting 75 seconds for cloud-init bootstrap..."
sleep 75

echo "🎉 Deployment Complete"
echo "--------------------------------------------------------"
echo "NiFi:        http://$PUBLIC_IP:8080"
echo "Artemis UI:  http://$PUBLIC_IP:8161"
echo "Kafka:       PLAINTEXT://$PUBLIC_IP:9092"
echo "ZooKeeper:   $PUBLIC_IP:2181"
echo "EventMesh:   http://$PUBLIC_IP:10105"
echo "SSH:         ssh -i ~/.ssh/$KEY_NAME.pem ubuntu@$PUBLIC_IP"
echo "--------------------------------------------------------"
