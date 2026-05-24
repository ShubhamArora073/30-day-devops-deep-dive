#!/usr/bin/env bash
# Day-01 teardown. Order matters:
#   1. Delete the LoadBalancer Service first (releases the ELB before VPC goes)
#   2. Delete the cluster (eksctl tears down CFN stacks: nodegroup → addons → cluster → VPC)
set -euo pipefail

CLUSTER="practice-cluster"
REGION="us-west-2"
LAB_DIR="$(cd "$(dirname "$0")/../labs/day-01-eks-cluster-setup" && pwd)"

echo ">>> Deleting demo Service (releases the ELB)..."
kubectl delete -f "$LAB_DIR/nginx-demo.yaml" --ignore-not-found=true

echo ">>> Waiting 30s for ELB de-provision..."
sleep 30

echo ">>> Deleting EKS cluster '$CLUSTER' in $REGION..."
eksctl delete cluster --name "$CLUSTER" --region "$REGION" --wait

echo ">>> Verifying no eksctl CFN stacks remain..."
REMAINING=$(aws cloudformation list-stacks --region "$REGION" \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE CREATE_IN_PROGRESS UPDATE_IN_PROGRESS DELETE_FAILED \
  --query "StackSummaries[?starts_with(StackName,'eksctl-${CLUSTER}')].StackName" \
  --output text 2>/dev/null || true)

if [[ -n "$REMAINING" ]]; then
  echo "WARNING — remaining stacks: $REMAINING"
  echo "Inspect in the CloudFormation console and delete manually."
  exit 1
fi

echo ">>> Day-1 cleanup complete. No EKS or eksctl-managed CFN stacks remain."
