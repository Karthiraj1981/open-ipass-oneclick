#!/usr/bin/env bash
set -Eeuo pipefail

REGION="${REGION:-ap-northeast-1}"
NAME_PREFIX="open-ipaas"

log(){ echo "[$(date +'%F %T%z')] $*"; }
trap 'log "❌ Error on line $LINENO"; exit 1' ERR

# Locate resources
vpc_id=$(aws ec2 describe-vpcs --region "$REGION" --filters "Name=tag:Name,Values=${NAME_PREFIX}-vpc" --query "Vpcs[0].VpcId" --output text 2>/dev/null || true)
subnet_id=$(aws ec2 describe-subnets --region "$REGION" --filters "Name=tag:Name,Values=${NAME_PREFIX}-subnet" --query "Subnets[0].SubnetId" --output text 2>/dev/null || true)
rtb_id=$(aws ec2 describe-route-tables --region "$REGION" --filters "Name=tag:Name,Values=${NAME_PREFIX}-rt" --query "RouteTables[0].RouteTableId" --output text 2>/dev/null || true)
sg_id=$(aws ec2 describe-security-groups --region "$REGION" --filters "Name=group-name,Values=${NAME_PREFIX}-sg" "Name=vpc-id,Values=${vpc_id}" --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || true)
igw_id=$(aws ec2 describe-internet-gateways --region "$REGION" --filters "Name=attachment.vpc-id,Values=${vpc_id}" --query "InternetGateways[0].InternetGatewayId" --output text 2>/dev/null || true)

# Terminate instances in this subnet/sg (defensive)
inst_ids=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=subnet-id,Values=${subnet_id}" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query "Reservations[].Instances[].InstanceId" --output text 2>/dev/null || true)
if [[ -n "$inst_ids" ]]; then
  log "🛑 Terminating instances: $inst_ids"
  aws ec2 terminate-instances --region "$REGION" --instance-ids $inst_ids >/dev/null
  aws ec2 wait instance-terminated --region "$REGION" --instance-ids $inst_ids
fi

# SG
if [[ -n "$sg_id" && "$sg_id" != "None" ]]; then
  log "🧹 Deleting SG $sg_id"
  aws ec2 delete-security-group --region "$REGION" --group-id "$sg_id" >/dev/null || true
fi

# RTB: delete default route then the RTB, disassociate if needed
if [[ -n "$rtb_id" && "$rtb_id" != "None" ]]; then
  log "🧹 Cleaning Route Table $rtb_id"
  # Disassociate all subnet associations except main
  assoc_ids=$(aws ec2 describe-route-tables --region "$REGION" --route-table-ids "$rtb_id" \
              --query "RouteTables[0].Associations[?Main==\`false\`].RouteTableAssociationId" --output text 2>/dev/null || true)
  for a in $assoc_ids; do
    aws ec2 disassociate-route-table --region "$REGION" --association-id "$a" >/dev/null || true
  done
  aws ec2 delete-route --region "$REGION" --route-table-id "$rtb_id" --destination-cidr-block 0.0.0.0/0 >/dev/null 2>&1 || true
  aws ec2 delete-route-table --region "$REGION" --route-table-id "$rtb_id" >/dev/null || true
fi

# Subnet
if [[ -n "$subnet_id" && "$subnet_id" != "None" ]]; then
  log "🧹 Deleting Subnet $subnet_id"
  aws ec2 delete-subnet --region "$REGION" --subnet-id "$subnet_id" >/dev/null || true
fi

# IGW
if [[ -n "$igw_id" && "$igw_id" != "None" ]]; then
  log "🧹 Detaching & deleting IGW $igw_id"
  aws ec2 detach-internet-gateway --region "$REGION" --internet-gateway-id "$igw_id" --vpc-id "$vpc_id" >/dev/null 2>&1 || true
  aws ec2 delete-internet-gateway --region "$REGION" --internet-gateway-id "$igw_id" >/dev/null || true
fi

# VPC
if [[ -n "$vpc_id" && "$vpc_id" != "None" ]]; then
  log "🧹 Deleting VPC $vpc_id"
  aws ec2 delete-vpc --region "$REGION" --vpc-id "$vpc_id" >/dev/null || true
fi

log "✅ Delete complete"
