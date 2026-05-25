#!/usr/bin/env bash
# Week-01 muscle-memory replay: rebuild Days 01-05 from a cluster-less start.
# Total time: ~45 min (EKS create dominates at ~15-20 min).
# Expected outcome: BG-with-analysis Rollout sitting Healthy on podinfo, ready
# to demo a canary or blue-green flow.
#
# Prereqs:
#   - AWS creds exported (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN)
#   - eksctl, kubectl, helm, kubectl-argo-rollouts on PATH
#   - Run from repo root: ./labs/week-01-consolidation/replay.sh
#
# Notes:
#   - Uses the DEV variant of the EKS cluster (cheap, 2 AZs, 1 NAT, no KMS).
#   - For the PROD variant (3 AZs, HA NAT, KMS-encrypted secrets), follow
#     labs/day-01-eks-cluster-setup/README.md "Going Production" section.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

export KUBECONFIG="$REPO_ROOT/.kubeconfig-chaos"
export AWS_REGION="${AWS_REGION:-us-west-2}"
export AWS_DEFAULT_REGION="$AWS_REGION"

CLUSTER_NAME="practice-cluster"

echo "════════════════════════════════════════════════════════════════════"
echo "  WEEK 1 REPLAY  ·  ~45 min  ·  cluster: $CLUSTER_NAME"
echo "════════════════════════════════════════════════════════════════════"

# ─── 0. Sanity ──────────────────────────────────────────────────────────
echo "▶ 0/6  · verifying creds + tooling"
aws sts get-caller-identity >/dev/null
command -v eksctl >/dev/null
command -v helm >/dev/null
command -v kubectl-argo-rollouts >/dev/null || command -v kubectl >/dev/null
echo "  ✔ creds + tools OK"

# ─── 1. Day 01 — create cluster ─────────────────────────────────────────
echo
echo "▶ 1/6  · Day-01: create EKS cluster (~15-20 min)"
if eksctl get cluster --region "$AWS_REGION" --name "$CLUSTER_NAME" >/dev/null 2>&1; then
  echo "  ✔ cluster already exists, skipping create"
else
  eksctl create cluster -f labs/day-01-eks-cluster-setup/eksctl-cluster.yaml
fi
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" --kubeconfig "$KUBECONFIG"
kubectl get nodes
echo "  ✔ cluster ready"

# ─── 2. Day 01 — deploy nginx (just to get an ELB hostname) ─────────────
echo
echo "▶ 2/6  · Day-01: deploy nginx + LoadBalancer Service"
kubectl apply -f labs/day-01-eks-cluster-setup/nginx-demo.yaml
echo "  ⏳ waiting for ELB hostname..."
for i in $(seq 1 30); do
  ELB=$(kubectl get svc web -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
  [ -n "$ELB" ] && break
  sleep 10
done
echo "  ✔ ELB: $ELB"

# ─── 3. Day 02 — install Argo Rollouts ──────────────────────────────────
echo
echo "▶ 3/6  · Day-02: install Argo Rollouts controller + CRDs"
kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argo-rollouts \
  -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
kubectl rollout status -n argo-rollouts deploy/argo-rollouts --timeout=3m
echo "  ✔ Argo Rollouts running"

# ─── 4. Day 04 — install Prometheus stack ───────────────────────────────
echo
echo "▶ 4/6  · Day-04: install kube-prometheus-stack (~3 min)"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null
if helm status kps -n monitoring >/dev/null 2>&1; then
  echo "  ✔ kps already installed, skipping"
else
  helm install kps prometheus-community/kube-prometheus-stack \
    --create-namespace --namespace monitoring \
    --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
    --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
    --set prometheus.prometheusSpec.ruleSelectorNilUsesHelmValues=false \
    --set grafana.adminPassword=admin \
    --wait --timeout 8m
fi
echo "  ✔ Prometheus + Grafana + Alertmanager up"

# ─── 5. Replace nginx with podinfo Rollout (BG strategy) ────────────────
echo
echo "▶ 5/6  · Day-05: migrate Deployment → BlueGreen Rollout (podinfo)"
kubectl delete deployment web --ignore-not-found
kubectl patch svc web --type=merge -p '{"spec":{"selector":{"app":"web"}}}'

kubectl apply -f labs/day-05-blue-green/preview-service.yaml
kubectl apply -f labs/day-04-analysis-auto-canary/pod-monitor.yaml
kubectl apply -f labs/day-04-analysis-auto-canary/analysis-template.yaml
kubectl apply -f labs/day-05-blue-green/loadgen-preview.yaml
kubectl apply -f labs/day-05-blue-green/rollout-with-analysis.yaml

echo "  ⏳ waiting for rollout to become Healthy (~60s)..."
for i in $(seq 1 18); do
  PHASE=$(kubectl get rollout web -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  [ "$PHASE" = "Healthy" ] && break
  sleep 10
done
kubectl argo rollouts get rollout web | head -15
echo "  ✔ rollout Healthy on podinfo:6.7.0"

# ─── 6. Summary ─────────────────────────────────────────────────────────
echo
echo "▶ 6/6  · Ready to demo"
echo "════════════════════════════════════════════════════════════════════"
echo
echo "Next moves you can run by hand:"
echo
echo "  # Demo A (auto-promote on a good image)"
echo "  kubectl argo rollouts set image web podinfo=ghcr.io/stefanprodan/podinfo:6.7.1"
echo "  kubectl argo rollouts get rollout web --watch"
echo
echo "  # Demo B (auto-abort on a 500-injecting image)"
echo "  kubectl apply -f labs/day-04-analysis-auto-canary/rollout-bad.yaml"
echo "  kubectl argo rollouts get rollout web --watch"
echo
echo "  # Open the Argo Rollouts dashboard"
echo "  kubectl argo rollouts dashboard"
echo "  # open http://localhost:3100/rollouts"
echo
echo "  # Open Prometheus / Grafana"
echo "  kubectl -n monitoring port-forward svc/kps-grafana 3000:80"
echo "  kubectl -n monitoring port-forward svc/kps-kube-prometheus-stack-prometheus 9090:9090"
echo
echo "When you're done, run:  ./labs/week-01-consolidation/teardown.sh"
echo "════════════════════════════════════════════════════════════════════"
