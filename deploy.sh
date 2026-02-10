#!/usr/bin/env bash
set -Eeuo pipefail

# ===== Config (adjust if needed) =====
REGION="${REGION:-ap-northeast-1}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.medium}"
KEY_NAME="${KEY_NAME:-ipass-dev-key}"
TAG_NAME="${TAG_NAME:-open-ipaas-ec2}"
USER_DATA_URL="${USER_DATA_URL:-https://raw.githubusercontent.com/Karthiraj1981/open-ipass-oneclick/main/cloud-init.yaml}"

NAME_PREFIX="open-ipaas"
VPC_CIDR="10.0.0.0/16"
SUBNET_CIDR="10.0.1.0/24"
SSH_CIDR="${SSH_CIDR:-0.0.0.0/0}"           # tighten to your IP/CIDR when you’re done testing
EXTRA_PORTS=("22" "8080" "8161" "61616" "9092" "10105" "10000" "10205")

log(){ echo "[$(date +'%F %T%z')] $*"; }
trap 'log "❌ Error on line $LINENO"; exit 1' ERR

# ----- Helpers -----
get_vpc(){ aws ec2 describe-vpcs --region "$REGION" --filters "Name=tag:Name,Values=${NAME_PREFIX}-vpc" --query "Vpcs[0].VpcId" --output text 2>/dev/null || true; }
get_subnet(){ aws ec2 describe-subnets --region "$REGION" --filters "Name=tag:Name,Values=${NAME_PREFIX}-subnet" --query "Subnets[0].SubnetId" --output text 2>/dev/null || true; }
get_rtb(){ aws ec2 describe-route-tables --region "$REGION" --filters "Name=tag:Name,Values=${NAME_PREFIX}-rt" --query "RouteTables[0].RouteTableId" --output text 2>/dev/null || true; }
get_igw_attached(){ local vpc_id="$1"; aws ec2 describe-internet-gateways --region "$REGION" --filters "Name=attachment.vpc-id,Values=${vpc_id}" --query "InternetGateways[0].InternetGatewayId" --output text 2>/dev/null || true; }
get_key(){ aws ec2 describe-key-pairs --region "$REGION" --key-names "$KEY_NAME" --query "KeyPairs[0].KeyName" --output text 2>/dev/null || true; }

# ----- VPC -----
vpc_id="$(get_vpc)"
if [[ -z "$vpc_id" || "$vpc_id" == "None" ]]; then
  log "🆕 Creating VPC $VPC_CIDR"
  vpc_id=$(aws ec2 create-vpc --region "$REGION" --cidr-block "$VPC_CIDR" --query "Vpc.VpcId" --output text)
  aws ec2 create-tags --region "$REGION" --resources "$vpc_id" --tags Key=Name,Value="${NAME_PREFIX}-vpc"
else
  log "♻️ Reusing VPC: $vpc_id"
fi
aws ec2 modify-vpc-attribute --region "$REGION" --vpc-id "$vpc_id" --enable-dns-support
aws ec2 modify-vpc-attribute --region "$REGION" --vpc-id "$vpc_id" --enable-dns-hostnames

# ----- Subnet (pick first available AZ robustly) -----
subnet_id="$(get_subnet)"
if [[ -z "$subnet_id" || "$subnet_id" == "None" ]]; then
  az=$(aws ec2 describe-availability-zones --region "$REGION" --query "AvailabilityZones[?State=='available']|[0].ZoneName" --output text)
  log "🆕 Creating Subnet $SUBNET_CIDR in $az"
  subnet_id=$(aws ec2 create-subnet --region "$REGION" --vpc-id "$vpc_id" --cidr-block "$SUBNET_CIDR" --availability-zone "$az" --query "Subnet.SubnetId" --output text)
  aws ec2 create-tags --region "$REGION" --resources "$subnet_id" --tags Key=Name,Value="${NAME_PREFIX}-subnet"
else
  log "♻️ Reusing Subnet: $subnet_id"
fi
aws ec2 modify-subnet-attribute --region "$REGION" --subnet-id "$subnet_id" --map-public-ip-on-launch

# ----- IGW (ensure ATTACHED to this VPC) -----
igw_attached="$(get_igw_attached "$vpc_id")"
if [[ -z "$igw_attached" || "$igw_attached" == "None" ]]; then
  log "🆕 Creating & attaching IGW"
  igw_id=$(aws ec2 create-internet-gateway --region "$REGION" --query "InternetGateway.InternetGatewayId" --output text)
  aws ec2 create-tags --region "$REGION" --resources "$igw_id" --tags Key=Name,Value="${NAME_PREFIX}-igw"
  aws ec2 attach-internet-gateway --region "$REGION" --internet-gateway-id "$igw_id" --vpc-id "$vpc_id"
  sleep 2
else
  igw_id="$igw_attached"
  log "✅ IGW attached to VPC: $igw_id"
fi

# ----- Route table (ensure default route ACTIVE and association) -----
rtb_id="$(get_rtb)"
if [[ -z "$rtb_id" || "$rtb_id" == "None" ]]; then
  log "🆕 Creating Route Table"
  rtb_id=$(aws ec2 create-route-table --region "$REGION" --vpc-id "$vpc_id" --query "RouteTable.RouteTableId" --output text)
  aws ec2 create-tags --region "$REGION" --resources "$rtb_id" --tags Key=Name,Value="${NAME_PREFIX}-rt"
else
  log "♻️ Reusing Route Table: $rtb_id"
fi

# Ensure default route exists and is active (recreate if blackhole)
route_state=$(aws ec2 describe-route-tables --region "$REGION" --route-table-ids "$rtb_id" \
               --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0']|[0].State" --output text 2>/dev/null || true)
if [[ -z "$route_state" || "$route_state" == "None" ]]; then
  log "➕ Adding default route 0.0.0.0/0 → $igw_id"
  aws ec2 create-route --region "$REGION" --route-table-id "$rtb_id" --destination-cidr-block 0.0.0.0/0 --gateway-id "$igw_id" >/dev/null
elif [[ "$route_state" == "blackhole" ]]; then
  log "🧹 Found blackhole route — recreating"
  aws ec2 delete-route --region "$REGION" --route-table-id "$rtb_id" --destination-cidr-block 0.0.0.0/0 || true
  aws ec2 create-route --region "$REGION" --route-table-id "$rtb_id" --destination-cidr-block 0.0.0.0/0 --gateway-id "$igw_id" >/dev/null
else
  log "✅ Default route ACTIVE"
fi

# Associate/replace association for this subnet to this RTB
assoc_id=$(aws ec2 describe-route-tables --region "$REGION" --filters "Name=association.subnet-id,Values=${subnet_id}" \
            --query "RouteTables[0].Associations[?SubnetId=='${subnet_id}']|[0].RouteTableAssociationId" --output text 2>/dev/null || true)
current_rtb=$(aws ec2 describe-route-tables --region "$REGION" --filters "Name=association.subnet-id,Values=${subnet_id}" \
             --query "RouteTables[0].Associations[?SubnetId=='${subnet_id}']|[0].RouteTableId" --output text 2>/dev/null || true)

if [[ -n "$assoc_id" && "$assoc_id" != "None" && -n "$current_rtb" && "$current_rtb" != "$rtb_id" ]]; then
  log "🔁 Replacing subnet association from $current_rtb → $rtb_id"
  aws ec2 replace-route-table-association --region "$REGION" --association-id "$assoc_id" --route-table-id "$rtb_id" >/dev/null
elif [[ -z "$assoc_id" || "$assoc_id" == "None" ]]; then
  log "🔗 Associating RTB $rtb_id → Subnet $subnet_id"
  aws ec2 associate-route-table --region "$REGION" --route-table-id "$rtb_id" --subnet-id "$subnet_id" >/dev/null
else
  log "✅ Subnet already associated to RTB $rtb_id"
fi

# ----- Security group -----
sg_id=$(aws ec2 describe-security-groups --region "$REGION" \
         --filters "Name=group-name,Values=${NAME_PREFIX}-sg" "Name=vpc-id,Values=${vpc_id}" \
         --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || true)
if [[ -z "$sg_id" || "$sg_id" == "None" ]]; then
  log "🆕 Creating Security Group"
  sg_id=$(aws ec2 create-security-group --region "$REGION" --vpc-id "$vpc_id" --group-name "${NAME_PREFIX}-sg" --description "Open iPaaS SG" --query "GroupId" --output text)
  aws ec2 create-tags --region "$REGION" --resources "$sg_id" --tags Key=Name,Value="${NAME_PREFIX}-sg"
else
  log "♻️ Reusing Security Group: $sg_id"
fi
for PORT in "${EXTRA_PORTS[@]}"; do
  aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$sg_id" --protocol tcp --port "$PORT" --cidr "$SSH_CIDR" >/dev/null 2>&1 || true
done

# ----- Key pair (reuse or create) -----
if [[ "$(get_key)" == "$KEY_NAME" ]]; then
  log "♻️ Reusing Key Pair: $KEY_NAME"
else
  log "🆕 Creating Key Pair: $KEY_NAME"
  mkdir -p "$HOME/.ssh"
  aws ec2 create-key-pair --region "$REGION" --key-name "$KEY_NAME" --key-type rsa --key-format pem --query "KeyMaterial" --output text > "$HOME/.ssh/${KEY_NAME}.pem"
  chmod 400 "$HOME/.ssh/${KEY_NAME}.pem"
fi

# ----- AMI -----
log "🔎 Finding latest Ubuntu 22.04 LTS"
AMI_ID=$(aws ec2 describe-images --region "$REGION" --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" "Name=architecture,Values=x86_64" \
  --query "sort_by(Images,&CreationDate)[-1].ImageId" --output text)
ROOT_DEVICE=$(aws ec2 describe-images --region "$REGION" --image-ids "$AMI_ID" --query "Images[0].RootDeviceName" --output text)

# ----- Launch EC2 -----
log "🚀 Launching EC2..."
user_data_arg=()
if [[ -n "$USER_DATA_URL" ]]; then
  user_data_arg=( --user-data "$(curl -fsSL "$USER_DATA_URL")" )
fi

INSTANCE_ID=$(aws ec2 run-instances --region "$REGION" \
  --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" \
  --subnet-id "$subnet_id" --security-group-ids "$sg_id" \
  --key-name "$KEY_NAME" --associate-public-ip-address \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${TAG_NAME}}]" \
  "${user_data_arg[@]}" \
  --block-device-mappings "[
    { \"DeviceName\": \"${ROOT_DEVICE}\",
      \"Ebs\": {\"VolumeSize\": 30, \"VolumeType\": \"gp3\", \"DeleteOnTermination\": true, \"Encrypted\": true}
    }
  ]" \
  --query 'Instances[0].InstanceId' --output text)

log "⏳ Waiting for running + 2/2 checks..."
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"
aws ec2 wait instance-status-ok --region "$REGION" --instance-ids "$INSTANCE_ID"

PUBLIC_IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
log "🌐 Public IP: $PUBLIC_IP"
log "⏳ Waiting for cloud-init (75s)..."; sleep 75

echo "🎉 Deployment Complete!"
echo "NiFi:      http://$PUBLIC_IP:8080"
echo "Artemis:   http://$PUBLIC_IP:8161"
echo "Kafka:     $PUBLIC_IP:9092"
echo "EventMesh: http://$PUBLIC_IP:10105"
echo "SSH:       ssh -i ~/.ssh/${KEY_NAME}.pem ubuntu@$PUBLIC_IP"
