#!/usr/bin/env bash
set -euo pipefail

REGION="ap-northeast-1"

echo "🗑️  Open iPaaS Cleanup (Tokyo Region)"
echo "--------------------------------------------"

###############################################################################
# 1. TERMINATE EC2 INSTANCE
###############################################################################
echo "🔍 Checking for EC2 instance tagged 'open-ipaas-ec2'..."

INSTANCE_ID=$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters "Name=tag:Name,Values=open-ipaas-ec2" "Name=instance-state-name,Values=running,stopped,stopping" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text)

if [[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != "None" ]]; then
  echo "🛑 Terminating EC2 instance: $INSTANCE_ID"
  aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID" >/dev/null
  aws ec2 wait instance-terminated --region "$REGION" --instance-ids "$INSTANCE_ID"
  echo "✔ EC2 terminated"
else
  echo "✔ No EC2 instance found."
fi


###############################################################################
# 2. DELETE SECURITY GROUP
###############################################################################
echo "🔍 Checking Security Group 'open-ipaas-sg'..."
SG_ID=$(aws ec2 describe-security-groups \
  --region "$REGION" \
  --filters "Name=group-name,Values=open-ipaas-sg" \
  --query "SecurityGroups[0].GroupId" \
  --output text 2>/dev/null || true)

if [[ -n "$SG_ID" && "$SG_ID" != "None" ]]; then
  echo "🗑️  Deleting Security Group: $SG_ID"

  # Remove ingress rules first
  RULE_IDS=$(aws ec2 describe-security-group-rules \
    --region "$REGION" \
    --filters "Name=group-id,Values=$SG_ID" \
    --query "SecurityGroupRules[].SecurityGroupRuleId" \
    --output text)

  for RULE in $RULE_IDS; do
    aws ec2 revoke-security-group-ingress \
      --region "$REGION" \
      --group-id "$SG_ID" \
      --security-group-rule-ids "$RULE" 2>/dev/null || true
  done

  aws ec2 delete-security-group --region "$REGION" --group-id "$SG_ID" || true
  echo "✔ SG deleted"
else
  echo "✔ No SG found."
fi


###############################################################################
# 3. GET VPC ID
###############################################################################
echo "🔍 Checking VPC 'open-ipaas-vpc'..."
VPC_ID=$(aws ec2 describe-vpcs \
  --region "$REGION" \
  --filters "Name=tag:Name,Values=open-ipaas-vpc" \
  --query "Vpcs[0].VpcId" \
  --output text 2>/dev/null || true)

if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
  echo "✔ No VPC found. Nothing else to delete."
  exit 0
fi

echo "✔ Found VPC: $VPC_ID"


###############################################################################
# 4. ROUTE TABLES
###############################################################################
echo "🔍 Checking Route Table 'open-ipaas-rt'..."
RT_ID=$(aws ec2 describe-route-tables \
  --region "$REGION" \
  --filters "Name=tag:Name,Values=open-ipass-rt" \
  --query "RouteTables[0].RouteTableId" \
  --output text 2>/dev/null || true)

if [[ -n "$RT_ID" && "$RT_ID" != "None" ]]; then
  echo "🗑️  Deleting Route Table: $RT_ID"

  # Disassociate subnets
  ASSOC_IDS=$(aws ec2 describe-route-tables \
    --region "$REGION" \
    --route-table-ids "$RT_ID" \
    --query "RouteTables[0].Associations[].RouteTableAssociationId" \
    --output text)

  for A in $ASSOC_IDS; do
    aws ec2 disassociate-route-table --association-id "$A" --region "$REGION" || true
  done

  # Remove default route
  aws ec2 delete-route --route-table-id "$RT_ID" --destination-cidr-block 0.0.0.0/0 --region "$REGION" 2>/dev/null || true

  aws ec2 delete-route-table --route-table-id "$RT_ID" --region "$REGION"
  echo "✔ Route Table deleted"
else
  echo "✔ No Route Table found."
fi


###############################################################################
# 5. DELETE SUBNET
###############################################################################
echo "🔍 Checking Subnet 'open-ipaas-subnet'..."
SUBNET_ID=$(aws ec2 describe-subnets \
  --region "$REGION" \
  --filters "Name=tag:Name,Values=open-ipaas-subnet" \
  --query "Subnets[0].SubnetId" \
  --output text 2>/dev/null || true)

if [[ -n "$SUBNET_ID" && "$SUBNET_ID" != "None" ]]; then
  echo "🗑️  Deleting Subnet: $SUBNET_ID"
  aws ec2 delete-subnet --subnet-id "$SUBNET_ID" --region "$REGION"
  echo "✔ Subnet deleted"
else
  echo "✔ No Subnet found."
fi


###############################################################################
# 6. DELETE INTERNET GATEWAY
###############################################################################
echo "🔍 Checking IGW 'open-ipaas-igw'..."
IGW_ID=$(aws ec2 describe-internet-gateways \
  --region "$REGION" \
  --filters "Name=tag:Name,Values=open-ipaas-igw" \
  --query "InternetGateways[0].InternetGatewayId" \
  --output text 2>/dev/null || true)

if [[ -n "$IGW_ID" && "$IGW_ID" != "None" ]]; then
  echo "🗑️  Detaching & Deleting IGW: $IGW_ID"

  aws ec2 detach-internet-gateway \
    --internet-gateway-id "$IGW_ID" \
    --vpc-id "$VPC_ID" \
    --region "$REGION" 2>/dev/null || true

  aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" --region "$REGION"
  echo "✔ IGW deleted"
else
  echo "✔ No IGW found."
fi


###############################################################################
# 7. CLEAN UP ENIs (CRITICAL)
###############################################################################
echo "🔍 Cleaning up orphan ENIs..."
ENIS=$(aws ec2 describe-network-interfaces \
  --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "NetworkInterfaces[].NetworkInterfaceId" \
  --output text)

for ENI in $ENIS; do
  echo "🗑️  Deleting ENI: $ENI"
  aws ec2 delete-network-interface --network-interface-id "$ENI" --region "$REGION" 2>/dev/null || true
done


###############################################################################
# 8. DELETE VPC
###############################################################################
echo "🗑️  Deleting VPC: $VPC_ID"
aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$REGION"
echo "✔ VPC deleted"

echo ""
echo "🎉 Cleanup complete — All Open iPaaS resources removed!"
