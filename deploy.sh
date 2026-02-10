#!/usr/bin/env bash
set -e

# --------------------------------------------------------
# Open iPaaS Minimal Deploy (Only Key Pair Reuse)
# - No SG reuse
# - Always creates NEW SG with required ports
# - Uses DEFAULT VPC + DEFAULT SUBNET
# - Minimal IAM permissions required
# --------------------------------------------------------

REGION="ap-northeast-1"
INSTANCE_TYPE="t3.medium"
KEY_NAME="ipass-dev-key"
TAG_NAME="open-ipass-ec2"

USER_DATA_URL="https://raw.githubusercontent.com/Karthiraj1981/open-ipass-oneclick/main/cloud-init.yaml"

echo "🚀 Starting Open iPaaS Deployment (Minimal Mode)"
echo "🌏 Region: $REGION"
echo "🔑 Using existing EC2 Key Pair: $KEY_NAME"
echo ""

# --------------------------------------------------------
# 1. Create NEW Security Group (every run)
# --------------------------------------------------------

SG_NAME="ipass-sg-$(date +%s)"
echo "🛡 Creating NEW Security Group: $SG_NAME"

SG_ID=$(aws ec2 create-security-group \
  --region "$REGION" \
  --group-name "$SG_NAME" \
  --description "Open iPaaS SG (Auto)" \
  --query 'GroupId' \
  --output text)

echo "   ✔ SG ID: $SG_ID"
echo "🌍 Opening inbound ports..."

# Required ports
REQUIRED_PORTS=(22 8080 8161 61616 9092 2181 10105)

for PORT in "${REQUIRED_PORTS[@]}"; do
  aws ec2 authorize-security-group-ingress \
    --region "$REGION" \
    --group-id "$SG_ID" \
    --protocol tcp \
    --port "$PORT" \
    --cidr 0.0.0.0/0 >/dev/null
done

echo "   ✔ All required ports opened"


# --------------------------------------------------------
# 2. Hardcoded Ubuntu AMI for ap-northeast-1
# --------------------------------------------------------

echo "🖼 Using static Ubuntu 22.04 LTS AMI…"
AMI_ID="ami-0f5a7f590cbf5a3dc"   # Tokyo region Ubuntu 22.04
echo "   ✔ AMI: $AMI_ID"


# --------------------------------------------------------
# 3. Launch EC2 (default VPC + public IP auto assigned)
# --------------------------------------------------------

echo "🚀 Launching EC2 instance..."

INSTANCE_ID=$(aws ec2 run-instances \
  --region "$REGION" \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --security-group-ids "$SG_ID" \
  --key-name "$KEY_NAME" \
  --associate-public-ip-address \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$TAG_NAME}]" \
  --user-data "$(curl -fsSL $USER_DATA_URL)" \
  --query "Instances[0].InstanceId" \
  --output text)

echo "   ✔ EC2 Instance ID: $INSTANCE_ID"
echo "⏳ Waiting for EC2 to become 'running'..."
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"


# --------------------------------------------------------
# 4. Fetch Public IP
# --------------------------------------------------------

PUBLIC_IP=$(aws ec2 describe-instances \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].PublicIpAddress" \
  --output text)

echo ""
echo "🌍 Public IP: $PUBLIC_IP"
echo "⏳ Waiting 75 seconds for cloud-init to install services…"
sleep 75

# --------------------------------------------------------
# 5. Display Service URLs
# --------------------------------------------------------

echo ""
echo "🎉 Deployment Complete! Your Open iPaaS stack is ready."
echo "--------------------------------------------------------"
echo "NiFi UI:       http://$PUBLIC_IP:8080"
echo "Artemis UI:    http://$PUBLIC_IP:8161"
echo "Artemis JMS:   $PUBLIC_IP:61616"
echo "Kafka Broker:  PLAINTEXT://$PUBLIC_IP:9092"
echo "ZooKeeper:     $PUBLIC_IP:2181"
echo "EventMesh:     http://$PUBLIC_IP:10105"
echo "--------------------------------------------------------"
echo "SSH into your instance:"
echo "   ssh -i ~/.ssh/${KEY_NAME}.pem ubuntu@$PUBLIC_IP"
echo ""
echo "Check logs on EC2:"
echo "   sudo tail -n 200 /var/log/cloud-init-output.log"
echo "   docker ps -a"
