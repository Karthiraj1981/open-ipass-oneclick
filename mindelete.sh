#!/usr/bin/env bash
set -e

REGION="ap-northeast-1"

echo "🗑️  Starting CLEAN DELETE for Open iPaaS VPC Deployment..."
echo "🌏 Region: $REGION"
echo ""

# ---------------------------------------------------------------
# 1. TERMINATE EC2 INSTANCE
# ---------------------------------------------------------------

echo "🔍 Searching for EC2 instance tagged 'open-ipass-ec2'..."

INSTANCE_ID=$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters "Name=tag:Name,Values=open-ipass-ec2" "Name=instance-state-name,Values=running,stopped" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text)

if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "None" ]]; then
  echo "✔ No EC2 instance found."
else
  echo "🛑 Terminating EC2 instance: $INSTANCE_ID"
  aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION" >/dev/null
  aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" --region "$REGION"
  echo "✔ EC2 terminated."
fi

echo ""

# ---------------------------------------------------------------
# 2. DELETE SECURITY GROUP
# ---------------------------------------------------------------

echo "🔍 Searching for auto-created SG (prefix: ipass-sg-)..."

SG_ID=$(aws ec2 describe-security-groups \
  --region "$REGION" \
  --query "SecurityGroups[?starts_with(GroupName, 'ipass-sg-')].GroupId" \
  --output text)

if [[ -z "$SG_ID" || "$SG_ID" == "None" ]]; then
  echo "✔ No auto-created SG found."
else
  echo "🛡 Deleting SG: $SG_ID"
  aws ec2 delete-security-group --group-id "$SG_ID" --region "$REGION" >/dev/null || true
  echo "✔ SG deleted."
fi

echo ""

# ---------------------------------------------------------------
# 3. GET VPC CREATED BY DEPLOYER
# ---------------------------------------------------------------

echo "🔍 Locating deployer-created VPC (CIDR 10.0.0.0/16)..."

VPC_ID=$(aws ec2 describe-vpcs \
  --region "$REGION" \
  --filters "Name=cidr,Values=10.0.0.0/16" \
  --query "Vpcs[0].VpcId" \
  --output text)

if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
  echo "✔ No deployer VPC found — nothing else to delete."
  exit 0
fi

echo "📦 Found VPC: $VPC_ID"
echo ""

# ---------------------------------------------------------------
# 4. DELETE SUBNET
# ---------------------------------------------------------------

echo "🔍 Deleting subnet in VPC..."

SUBNET_ID=$(aws ec2 describe-subnets \
  --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidr-block,Values=10.0.1.0/24" \
  --query "Subnets[0].SubnetId" \
  --output text)

if [[ -n "$SUBNET_ID" && "$SUBNET_ID" != "None" ]]; then
  echo "🧹 Deleting Subnet: $SUBNET_ID"
  aws ec2 delete-subnet --subnet-id "$SUBNET_ID" --region "$REGION" >/dev/null || true
  echo "✔ Subnet deleted."
else
  echo "✔ No deployer-created subnet found."
fi

echo ""

# ---------------------------------------------------------------
# 5. DELETE ROUTE TABLE
# ---------------------------------------------------------------

echo "🔍 Deleting Route Table..."

RT_ID=$(aws ec2 describe-route-tables \
  --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "RouteTables[?contains(Tags[?Key=='Name'].Value, 'open-ipass')].RouteTableId" \
  --output text)

# fallback match by VPC if tag missing
if [[ -z "$RT_ID" || "$RT_ID" == "None" ]]; then
  RT_ID=$(aws ec2 describe-route-tables \
    --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "RouteTables[0].RouteTableId" \
    --output text)
fi

if [[ -n "$RT_ID" && "$RT_ID" != "None" ]]; then
  echo "🛣 Removing routes & deleting RT: $RT_ID"

  # Try remove default route before delete
  aws ec2 delete-route \
    --region "$REGION" \
    --route-table-id "$RT_ID" \
    --destination-cidr-block 0.0.0.0/0 >/dev/null 2>&1 || true

  aws ec2 delete-route-table --route-table-id "$RT_ID" --region "$REGION" >/dev/null || true
  echo "✔ Route table deleted."
else
  echo "✔ No route table found."
fi

echo ""

# ---------------------------------------------------------------
# 6. DETACH + DELETE IGW
# ---------------------------------------------------------------

echo "🔍 Finding Internet Gateway..."

IGW_ID=$(aws ec2 describe-internet-gateways \
  --region "$REGION" \
  --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
  --query "InternetGateways[0].InternetGatewayId" \
  --output text)

if [[ -n "$IGW_ID" && "$IGW_ID" != "None" ]]; then
  echo "🌐 Detaching IGW: $IGW_ID"
  aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region "$REGION" >/dev/null || true

  echo "🗑️  Deleting IGW..."
  aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" --region "$REGION" >/dev/null || true

  echo "✔ IGW deleted."
else
  echo "✔ No IGW found."
fi

echo ""

# ---------------------------------------------------------------
# 7. DELETE VPC
# ---------------------------------------------------------------

echo "🧨 Deleting VPC: $VPC_ID"

aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$REGION" >/dev/null || true

echo "✔ VPC deleted."
echo ""
echo "🎉 FULL CLEANUP COMPLETE — all deployer-created resources removed."
