# Day 03 — Canary deployment with manual promotion (Argo Rollouts)

**Goal:** migrate an existing nginx Deployment to an Argo `Rollout`, then progressively
shift production traffic from `nginx:1.25` → `nginx:1.27` using a paused canary,
visualising the shift via HTTP `Server` headers, and finishing with an aborted
bad-image rollout to prove rollback works.

**Time:** ~25 min · **Cost:** $0 (reuses Day-01 cluster + ELB)

---

## Strategy at a glance

```
                  ┌──────────────────────────────┐
                  │  Service: web (LoadBalancer) │
                  │      selector: app=web       │
                  └──────────────┬───────────────┘
                                 │
                 ┌───────────────┴────────────────┐
                 │                                │
        ┌────────▼─────────┐            ┌─────────▼─────────┐
        │ ReplicaSet: web-<stable-rev>  │ ReplicaSet: web-<canary-rev>
        │ image: nginx:1.25  (N pods)   │ image: nginx:1.27  (K pods)
        └───────────────────────────────┴───────────────────┘
                  weight controlled by Rollout controller
                  via scaling the two ReplicaSets
```

Without a service mesh we use **replica-weighted canary**: the controller scales the
canary ReplicaSet to the % of pods matching `setWeight`, and the rest stays on stable.
With 4 replicas: 25% = 1 canary pod, 50% = 2, 75% = 3, 100% = 4 (stable retired).
Traffic split is approximate (kube-proxy / ELB round-robin across all ready pods
behind the Service); it’s not weighted routing. With Istio/SMI/ALB-TGB it would be.

Canary steps in `rollout.yaml`:

| step | weight | gate            | what to do                       |
|------|--------|-----------------|----------------------------------|
| 1    | 25%    | `pause: {}`     | **manual** — eyeball, then promote |
| 2    | 50%    | `pause: 30s`    | automatic bake                   |
| 3    | 75%    | `pause: 30s`    | automatic bake                   |
| 4    | 100%   | end of steps    | promotion completes              |

---

## Implementation

### 0 · Sanity check

```bash
export KUBECONFIG="$PWD/.kubeconfig-chaos"        # workspace kubeconfig from Day-01
kubectl argo rollouts version                     # plugin v1.9.0+
kubectl get deploy,svc web                        # current Day-01 Deployment + Service
```

### 1 · Replace Deployment with Rollout (Service stays)

The Service keeps the same selector `app=web`, so the same ELB hostname stays live
across the migration. Zero ELB churn = zero DNS churn.

```bash
kubectl delete deployment web                     # Service + ELB untouched
kubectl apply -f labs/day-03-canary-manual/rollout.yaml
kubectl argo rollouts get rollout web             # snapshot view
```

Wait until status shows `Healthy` and 4 pods `nginx:1.25`.

```bash
ELB=$(kubectl get svc web -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
for i in {1..10}; do curl -sI "http://$ELB/" | grep -i ^Server; done
# all 10 → Server: nginx/1.25.5
```

### 2 · Trigger canary: bump image to nginx:1.27

```bash
kubectl argo rollouts set image web nginx=nginx:1.27
```

Then in a second terminal, watch the controller drive the canary:

```bash
kubectl argo rollouts get rollout web --watch
```

You should see status go `Healthy → Progressing`, a new ReplicaSet spin up with
1/1 ready canary pod, and the Rollout stop at `Paused — CanaryPauseStep` (step 1).

Confirm traffic split (~25% from canary):

```bash
for i in {1..20}; do curl -sI "http://$ELB/" | grep -i ^Server; done | sort | uniq -c
# roughly 15× nginx/1.25.5  +  5× nginx/1.27.5  (varies)
```

### 3 · Promote manually past the gate

```bash
kubectl argo rollouts promote web
```

Watch the controller march through 50% → 30s pause → 75% → 30s pause → 100%.

```bash
for i in {1..20}; do curl -sI "http://$ELB/" | grep -i ^Server; done | sort | uniq -c
# all 20 → nginx/1.27.5  once promotion completes
```

### 4 · Bad-image rollout + abort + rollback

```bash
kubectl argo rollouts set image web nginx=nginx:does-not-exist
kubectl argo rollouts get rollout web --watch
```

Canary pod will go `ImagePullBackOff`. The Rollout will stay `Degraded` /
`Progressing` indefinitely (no AnalysisRun configured, so no auto-abort yet — that
comes Day-04). Manual abort + rollback:

```bash
kubectl argo rollouts abort web                   # marks rollout aborted
kubectl argo rollouts undo web                    # rollback to previous stable revision
# back to all nginx:1.27 pods, ELB still routing
```

---

## What the controller actually does (for the interview)

When you `set image`, the Rollout's `.spec.template` changes → controller computes a
new pod-template-hash → creates a new ReplicaSet. Instead of scaling old=0, new=N
all at once (Deployment behaviour), it:

1. Scales the canary RS to `ceil(replicas * setWeight / 100)` pods.
2. Scales the stable RS down by the same number, respecting `maxUnavailable=0` and
   `maxSurge=25%` to maintain capacity.
3. Updates `status.currentStepIndex` and `status.pauseConditions` per step.
4. Re-queues itself after `pause.duration` (or waits forever on `pause: {}`).
5. On `promote`, removes the pause condition → moves to the next step.
6. On `abort`, scales canary RS to 0 and stable RS back to spec.replicas.
7. On `undo`, points `.spec.template` back at the previous RS's template.

The Service selector `app=web` matches both ReplicaSets, so kube-proxy load-balances
across all ready pods. There is no Istio VirtualService, no ALB TargetGroupBinding,
no SMI TrafficSplit — just replica counts.

---

## Files

| file                 | purpose                                |
|----------------------|----------------------------------------|
| `rollout.yaml`       | Rollout CRD: canary strategy + steps   |
| `README.md`          | this guide                             |

The Day-01 `service.yaml` is reused as-is.

---

## Done when

- [x] `kubectl get rollout web` shows `Healthy` at `nginx:1.27`.
- [x] During canary pause, curl loop shows mixed `Server` headers in ~25:75 ratio.
- [x] After `promote`, all curls return `Server: nginx/1.27.5`.
- [x] `abort` + `undo` recovers a broken rollout without ELB downtime.


---

## Interview Q&A

**Q1. Rollout vs Deployment — what's the actual mechanical difference?**
Deployment is a built-in controller that owns ReplicaSets and does
RollingUpdate/Recreate. Rollout is a CRD with its own controller; it also owns
ReplicaSets but supports `canary` and `blueGreen` strategies with pause steps,
analysis-driven auto-promotion/abort, traffic-mesh integrations, experiment runs,
and rollback to any prior revision in history. The Pod spec on both is identical.

**Q2. How does Argo Rollouts shift traffic without a service mesh?**
By scaling the canary and stable ReplicaSets. Both have the Service selector, so
kube-proxy / cloud LB load-balances across all ready pods. The split is
replica-proportional, not weighted-routing-precise. For true 5% canary on low
replica counts you wire in Istio / SMI / NGINX / ALB so the Rollout writes a
weighted route resource instead of scaling pods.

**Q3. What happens if I `kubectl edit deployment` on a Rollout-managed app?**
Nothing — the Rollout doesn't own a Deployment. You'd be editing a stale or
non-existent resource. The Rollout's own controller reconciles its CRD spec; that's
the only mutation surface. Old Deployments must be deleted (as we did) before
creating the Rollout, otherwise both controllers fight over the same pods.

**Q4. `pause: {}` vs `pause: {duration: 30s}` — when to use which?**
`{}` is an indefinite manual gate — used for the first canary step where a human
inspects dashboards / receives PagerDuty silence / runs smoke tests. Time-bound
pauses are for automatic soak periods between increases (e.g., let connection
warm-up, JIT compile, error budgets stabilise). Production patterns: one manual
gate + several timed bakes + AnalysisTemplate gates on each step (Day-04).

**Q5. `abort` vs `undo` vs `rollback`?**
- `abort`: scales canary RS to 0, holds at current stable revision, marks rollout
  Degraded. Use mid-canary when metrics go red.
- `undo`: like `kubectl rollout undo` — points `.spec.template` at the previous
  ReplicaSet's pod template. Triggers a *new* rollout that goes through canary
  steps again unless you `--skip-current-step` or set `RestartAt`.
- "rollback" isn't a Rollout verb; people use it loosely for either.
