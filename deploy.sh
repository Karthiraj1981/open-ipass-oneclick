#!/usr/bin/env bash
set -euo pipefail

# --------------------------------------------
# Open iPaaS One-Click Deployer (REUSE KeyPair & SG)
# - Reuses existing Key Pair: ipass-dev-key
# - Reuses existing Security Group: launch-wizard-1
# - Ensures Subnet is public (auto-assign public IP + IGW + 0.0.0.0/0 route)
# Region: ap-northeast-1 (Tokyo)
# Instance: t3.medium
# --------------------------------------------

REGION="ap-northeast-1"
INSTANCE_TYPE="t3.medium"
TAG_NAME="open-ipass-ec2"
USER_DATA_URL="https://raw.githubusercontent.com/Karthiraj1981/open-ipass-oneclick/main/cloud-init.yaml"

KEY_NAME="ipass-dev-key"
REUSE_SG_NAME="launch-wizard-1"

echo "🔎 [1/9] Validating AWS identity and region..."
