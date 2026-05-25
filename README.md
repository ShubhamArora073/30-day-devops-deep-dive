# 30-Day DevOps Deep Dive

Hands-on labs covering progressive delivery, GitOps, infrastructure-as-code, cloud security, and observability on AWS + Kubernetes. Each day is a self-contained, runnable demo with a written walkthrough and interview-grade Q&A.

**Stack:** AWS (EKS, Lambda, API Gateway, IAM, VPC, CloudWatch, SSM) · Kubernetes · Argo Rollouts · ArgoCD · Terraform · Helm · Prometheus · Grafana · Python (boto3)

---

## Progress

| Day | Topic | Folder | Status |
|----:|-------|--------|--------|
| 01  | EKS cluster provisioning with `eksctl` (declarative) | [`labs/day-01-eks-cluster-setup`](labs/day-01-eks-cluster-setup) | done |
| 02  | Argo Rollouts installation + CRD walkthrough | [`labs/day-02-argo-rollouts-install`](labs/day-02-argo-rollouts-install) | done |
| 03  | Canary deployment with manual promotion | [`labs/day-03-canary-manual`](labs/day-03-canary-manual) | done |
| 04  | Automated analysis: error rate + p99 latency rollback | `labs/day-04-analysis-template` | pending |
| 05  | Blue-Green deployment strategy | `labs/day-05-blue-green` | pending |
| 06–07 | Week 1 consolidation & full demo replay | `labs/week-01-consolidation` | pending |
| 08  | Terraform fundamentals: VPC, subnets, SGs | `labs/day-08-terraform-vpc` | pending |
| 09  | Remote state (S3) + locking (DynamoDB) | `labs/day-09-remote-state` | pending |
| 10  | Reusable modules + per-environment composition | `labs/day-10-modules-envs` | pending |
| 11  | GitOps with ArgoCD (sync + drift correction) | `labs/day-11-argocd` | pending |
| 12  | Terraform PR workflow (plan-on-PR, apply-on-merge) | `labs/day-12-tf-pr-workflow` | pending |
| 13  | Insecure baseline: public API Gateway + over-privileged Lambdas | `labs/day-13-insecure-baseline` | pending |
| 14  | Excessive-permission identification (CloudTrail + Access Analyzer) | `labs/day-14-permission-audit` | pending |
| 15  | Private API Gateway via VPC Endpoint + resource policy | `labs/day-15-private-apigw` | pending |
| 16  | Least-privilege IAM rollout | `labs/day-16-least-privilege` | pending |
| 17  | Codify the entire security remediation as Terraform | `labs/day-17-security-iac` | pending |
| 18  | Prometheus + Grafana on EKS via kube-prometheus-stack | `labs/day-18-prometheus-stack` | pending |
| 19  | SLO alerts + error-budget burn-rate rules | `labs/day-19-slo-alerts` | pending |
| 20  | Python CloudWatch log analyzer (boto3) | `labs/day-20-log-analyzer` | pending |
| 21  | OS patching automation with SSM Patch Manager | `labs/day-21-ssm-patching` | pending |
| 22  | End-to-end architecture diagram & narrative | `labs/day-22-architecture` | pending |
| 23–28 | Mock interviews & final consolidation | `labs/week-04-revision` | pending |

---

## Repository Layout

```
30-day-devops-deep-dive/
├── README.md                 # this file — portfolio landing page
├── .gitignore                # excludes secrets, tfstate, kubeconfig, personal notes
└── labs/
    └── day-NN-<topic>/
        ├── README.md         # walkthrough + commands + gotchas + interview Q&A
        └── <manifests>.yaml  # the actual IaC / k8s / etc.
```

---

## How to Use This Repo

Each day's folder is self-contained. The README walks through setup, run, and teardown commands in order. To replay a day:

```bash
cd labs/day-NN-<topic>
cat README.md          # everything you need is here
```

---

## Cost Discipline

Most labs spin up real AWS resources. Every per-day README ends with the teardown commands in order. A billing alarm at $50 is the recommended safety net.

| Resource | Daily cost (us-west-2) | Lifecycle |
|---|---|---|
| EKS control plane | $2.40 | One cluster reused across Weeks 1–2 |
| EC2 worker nodes (3× t3.medium) | $3.00 | Stopped overnight where possible |
| NAT Gateway | $1.10 | Single-AZ during practice |
| ELB / NLB | $0.55 | Deleted after each lab |
| Lambda + API GW | Pennies | Negligible |
| S3 + DynamoDB (TF state) | Pennies | Always-on |

---

## License

MIT — see [`LICENSE`](LICENSE).
