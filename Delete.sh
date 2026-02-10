#!/usr/bin/env bash
set -euo pipefail

REGION="ap-northeast-1"

echo "🗑️  Open iPaaS One-Click Cleanup (Tokyo)"
echo "----------------------------------------"

# 1. Terminate EC2 instance
echo "🔎 Checking for EC2 instances tagged 'open-ipass-ec2'..."
INSTANCE_ID=$(aws ec2 describe-instances \
  --region $REGION \
  --filters "Name=tag:Name,Values=open-ipass-ec2" "Name=instance-state-name,Values=running,stopped" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text)

if [[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != "None" ]]; then
  echo "🛑 Terminating EC2 instance: $INSTANCE_ID"
  aws ec2 terminate-instances --instance-ids $INSTANCE_ID --region $REGION >/dev/null
  aws ec2 wait instance-terminated --instance-ids $INSTANCE_ID --region $REGION
  echo "   ✔ EC2 terminated"
else
  echo "   No EC2 instance found."
fi

# 2. Delete Security Group
echo "🔎 Checking Security Group..."
SG_ID=$(aws ec2 describe-security-groups \
  --region $REGION \
  --filters "Name=group-name,Values=open-ipass-sg" \
  --query "SecurityGroups[0].GroupId" \
  --output text 2>/dev/null || true)

if [[ -n "$SG_ID" && "$SG_ID" != "None" ]]; then
  echo "🗑️  Deleting Security Group: $SG_ID"
  aws ec2 delete-security-group --group-id $SG_ID --region $REGION || true
  echo "   ✔ Security Group deleted"
else
  echo "   No SG found."
fi

# 3. Get VPC ID
echo "🔎 Checking VPC 'open-ipass-vpc'..."
VPC_ID=$(aws ec2 describe-vpcs \
  --region $REGION \
  --filters "Name=tag:Name,Values=open-ipass-vpc" \
  --query "Vpcs[0].VpcId" \
  --output text 2>/dev/null || true)

if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
  echo "   No VPC found. Exiting."
  exit 0
else
  echo "   Found VPC: $VPC_ID"
fi

# 4. Route Table
echo "🔎 Checking Route Table..."
RT_ID=$(aws ec2 describe-route-tables \
  --region $REGION \
  --filters "Name=tag:Name,Values=open-ipass-rt" \
  --query "RouteTables[0].RouteTableId" \
  --output text 2>/dev/null || true)

if [[ -n "$RT_ID" && "$RT_ID" != "None" ]]; then
  echo "🗑️  Deleting Route Table: $RT_ID"

  # Delete any extra routes first
  set +e
  aws ec2 delete-route --route-table-id $RT_ID --destination-cidr-block 0.0.0.0/0 --region $REGION >/dev/null 2>&1
  set -e

  # Disassociate subnets
  ASSOC_IDS=$(aws ec2 describe-route-tables \
    --region $REGION \
    --route-table-ids $RT_ID \
    --query "RouteTables[0].Associations[].RouteTableAssociationId" \
    --output text)

  for assoc in $ASSOC_IDS; do
    aws ec2 disassociate-route-table --association-id $assoc --region $REGION >/dev/null || true
  done

  aws ec2 delete-route-table --route-table-id $RT_ID --region $REGION || true
  echo "   ✔ Route Table deleted"
else
  echo "   No Route Table found."
fi

# 5. Subnet
echo "🔎 Checking Subnet..."
SUBNET_ID=$(aws ec2 describe-subnets \
  --region $REGION \
  --filters "Name=tag:Name,Values=open-ipass-subnet" \
  --query "Subnets[0].SubnetId" \
  --output text 2>/dev/null || true)

if [[ -n "$SUBNET_ID" && "$SUBNET_ID" != "None" ]]; then
  echo "🗑️  Deleting Subnet: $SUBNET_ID"
  aws ec2 delete-subnet --subnet-id $SUBNET_ID --region $REGION
  echo "   ✔ Subnet deleted"
else
  echo "   No subnet found."
fi

# 6. Internet Gateway
echo "🔎 Checking Internet Gateway..."
IGW_ID=$(aws ec2 describe-internet-gateways \
  --region $REGION \
  --filters "Name=tag:Name,Values=open-ipass-igw" \
  --query "InternetGateways[0].InternetGatewayId" \
  --output text 2>/dev/null || true)

if [[ -n "$IGW_ID" && "$IGW_ID" != "None" ]]; then
  echo "🛑 Detaching and deleting IGW: $IGW_ID"
  set +e
  aws ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID --region $REGION >/dev/null
  set -e
  aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID --region $REGION
  echo "   ✔ IGW deleted"
else
  echo "   No IGW found."
fi

# 7. Delete VPC
echo "🗑️  Deleting VPC: $VPC_ID"
aws ec2 delete-vpc --vpc-id $VPC_ID --region $REGION
echo "   ✔ VPC deleted"

echo ""
echo "🎉 Cleanup complete — All one-click resources removed."
