#!/usr/bin/env bash
# Week-01 teardown: delete everything we built so the AWS bill stops.
# Order matters: app -> helm releases -> cluster -> (optionally) KMS key.
# Total time: ~10-15 min (cluster deletion is the slow part).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

export KUBECONFIG="${KUBECONFIG:-$REPO_ROOT/.kubeconfig-chaos}"
export AWS_REGION="${AWS_REGION:-us-west-2}"
export AWS_DEFAULT_REGION="$AWS_REGION"

CLUSTER_NAME="practice-cluster"

echo "════════════════════════════════════════════════════════════════════"
echo "  WEEK 1 TEARDOWN  ·  cluster: $CLUSTER_NAME · region: $AWS_REGION"
echo "════════════════════════════════════════════════════════════════════"

# ─── 1. Drain app objects (releases ELB before cluster delete) ─────────
echo
echo "▶ 1/4  · delete app workloads + Services (releases ELB)"
kubectl delete rollout web --ignore-not-found || true
kubectl delete deployment web --ignore-not-found || true
kubectl delete deployment loadgen --ignore-not-found || true
kubectl delete svc web web-canary web-preview --ignore-not-found || true
kubectl delete podmonitor web-podinfo --ignore-not-found || true
kubectl delete analysistemplate success-rate --ignore-not-found || true
kubectl delete analysisrun --all --ignore-not-found || true
echo "  ✔ workloads deleted (CLB takes ~30s to release)"

# ─── 2. Helm releases ────────────────────────────────────────────────────
echo
echo "▶ 2/4  · uninstall helm releases"
helm uninstall kps -n monitoring --ignore-not-found || true
kubectl delete ns monitoring --ignore-not-found --timeout=2m || true
kubectl delete ns argo-rollouts --ignore-not-found --timeout=2m || true
echo "  ✔ monitoring + argo-rollouts namespaces gone"

# ─── 3. EKS cluster ──────────────────────────────────────────────────────
echo
echo "▶ 3/4  · delete EKS cluster (~10-15 min)"
if eksctl get cluster --region "$AWS_REGION" --name "$CLUSTER_NAME" >/dev/null 2>&1; then
  eksctl delete cluster --region "$AWS_REGION" --name "$CLUSTER_NAME" --wait
  echo "  ✔ cluster deleted"
else
  echo "  ✔ no cluster to delete"
fi

# ─── 4. KMS (only if you used the prod config) ───────────────────────────
echo
echo "▶ 4/4  · (optional) schedule KMS CMK deletion if you used the prod config"
KMS_ARN=$(aws kms describe-key --key-id alias/eks-practice-cluster --region "$AWS_REGION" \
  --query 'KeyMetadata.Arn' --output text 2>/dev/null || echo "")
if [ -n "$KMS_ARN" ] && [ "$KMS_ARN" != "None" ]; then
  echo "  ⚠ found CMK: $KMS_ARN"
  read -r -p "  Schedule for deletion in 7 days? [y/N] " ans
  if [ "${ans:-N}" = "y" ] || [ "${ans:-N}" = "Y" ]; then
    aws kms delete-alias --alias-name alias/eks-practice-cluster --region "$AWS_REGION" || true
    aws kms schedule-key-deletion --key-id "$KMS_ARN" --pending-window-in-days 7 --region "$AWS_REGION"
    echo "  ✔ CMK scheduled for deletion in 7 days (reversible until then)"
  else
    echo "  ✔ leaving CMK alone — re-run aws kms commands manually if you want it gone"
  fi
else
  echo "  ✔ no CMK alias 'alias/eks-practice-cluster' found, skipping"
fi

echo
echo "════════════════════════════════════════════════════════════════════"
echo "  DONE.  Recommended next: aws ec2 describe-network-interfaces"
echo "          --filters Name=description,Values='*amazon-eks*'"
echo "          to confirm no orphan ENIs are still billing."
echo "════════════════════════════════════════════════════════════════════"
