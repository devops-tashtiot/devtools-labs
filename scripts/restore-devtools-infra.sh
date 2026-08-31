#!/usr/bin/env bash
set -euo pipefail

# Restores the devtools platform after a scale-down (manual, or the
# after-hours-shutdown Lambda/RDS nightly-stop schedule):
#   1. Restores both EKS managed node groups' desiredSize to their
#      Terraform-configured value (read live from
#      terraform/live/devtools/eks/terragrunt.hcl, falling back to
#      terraform/modules/eks/variables.tf's default if not overridden
#      there — so this script can't drift from what `terragrunt apply`
#      would set). min/max are deliberately left untouched — only
#      desiredSize is restored, since scaling-config accepts a partial
#      update and min/max aren't what an after-hours shutdown changes.
#   2. Starts the Windows AD domain controller EC2 instance (RHBK's LDAP
#      federation and Bitbucket's user directory both depend on it).
#   3. Starts the RDS instance every devtool's database depends on.
#
# All three steps are idempotent — safe to re-run if some resources are
# already up.

AWS_PROFILE="${AWS_PROFILE:-342831714456_Workload-Admin-PS}"
AWS_REGION="${AWS_REGION:-il-central-1}"
export AWS_PROFILE AWS_REGION

CLUSTER_NAME="devtools-eks"
RDS_IDENTIFIER="devtools-rds"
DC_INSTANCE_NAME="WIN-SRV-01"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAGRUNT_HCL="$SCRIPT_DIR/../terraform/live/devtools/eks/terragrunt.hcl"
VARIABLES_TF="$SCRIPT_DIR/../terraform/modules/eks/variables.tf"

hcl_int() {
  # $1 = terraform variable name. Prints the terragrunt.hcl override if
  # present, else the variable's own default from variables.tf.
  local key="$1" val
  val=$(grep -oP "^\s*${key}\s*=\s*\K[0-9]+" "$TERRAGRUNT_HCL" | head -1 || true)
  if [ -z "$val" ]; then
    val=$(grep -A5 "variable \"${key}\"" "$VARIABLES_TF" | grep -oP 'default\s*=\s*\K[0-9]+' | head -1)
  fi
  echo "$val"
}

NODE_DESIRED=$(hcl_int node_desired_size)
LARGE_DESIRED=$(hcl_int node_large_desired_size)

echo "== 1/3 Restoring EKS node groups' desired size (min/max left untouched) =="
echo "   devtools:       desired=$NODE_DESIRED"
echo "   devtools-large: desired=$LARGE_DESIRED"

NODEGROUPS=$(aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" --query "nodegroups" --output text)

for ng in $NODEGROUPS; do
  case "$ng" in
    devtools-large-*)
      aws eks update-nodegroup-config --cluster-name "$CLUSTER_NAME" --nodegroup-name "$ng" \
        --region "$AWS_REGION" --scaling-config "desiredSize=$LARGE_DESIRED" \
        --query "update.{id:id,status:status}" --output json
      ;;
    devtools-*)
      aws eks update-nodegroup-config --cluster-name "$CLUSTER_NAME" --nodegroup-name "$ng" \
        --region "$AWS_REGION" --scaling-config "desiredSize=$NODE_DESIRED" \
        --query "update.{id:id,status:status}" --output json
      ;;
    *)
      echo "   Skipping unrecognized node group: $ng"
      ;;
  esac
done

echo
echo "== 2/3 Domain controller EC2 instance ($DC_INSTANCE_NAME) =="
DC_STATE=$(aws ec2 describe-instances --region "$AWS_REGION" \
  --filters "Name=tag:Name,Values=${DC_INSTANCE_NAME}" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query "Reservations[0].Instances[0].State.Name" --output text 2>/dev/null || echo "not-found")

if [ "$DC_STATE" = "stopped" ]; then
  DC_INSTANCE_ID=$(aws ec2 describe-instances --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=${DC_INSTANCE_NAME}" "Name=instance-state-name,Values=stopped" \
    --query "Reservations[0].Instances[0].InstanceId" --output text)
  aws ec2 start-instances --instance-ids "$DC_INSTANCE_ID" --region "$AWS_REGION" \
    --query "StartingInstances[0].{Id:InstanceId,State:CurrentState.Name}" --output json
elif [ "$DC_STATE" = "not-found" ] || [ -z "$DC_STATE" ] || [ "$DC_STATE" = "None" ]; then
  echo "   WARNING: no instance tagged Name=${DC_INSTANCE_NAME} found — skipping."
else
  echo "   Already '$DC_STATE' — nothing to start."
fi

echo
echo "== 3/3 RDS instance ($RDS_IDENTIFIER) =="
RDS_STATUS=$(aws rds describe-db-instances --db-instance-identifier "$RDS_IDENTIFIER" --region "$AWS_REGION" \
  --query "DBInstances[0].DBInstanceStatus" --output text 2>/dev/null || echo "not-found")

if [ "$RDS_STATUS" = "stopped" ]; then
  aws rds start-db-instance --db-instance-identifier "$RDS_IDENTIFIER" --region "$AWS_REGION" \
    --query "DBInstance.DBInstanceStatus" --output text
elif [ "$RDS_STATUS" = "not-found" ]; then
  echo "   WARNING: RDS instance $RDS_IDENTIFIER not found — skipping."
else
  echo "   Already '$RDS_STATUS' — nothing to start."
fi

echo
echo "Done. Nodes typically join in ~1-2 min, the domain controller finishes booting Windows in ~3-5 min, and RDS becomes available in ~5 min."
