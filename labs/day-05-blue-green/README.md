# Day 05 — Blue-Green deployment with Argo Rollouts

**Goal:** spin up the new version (green) at full size next to the old one (blue),
validate it via a private `previewService`, then **flip the `activeService`
selector in one atomic move** so ELB traffic cuts over instantly. Keep blue warm
for `scaleDownDelaySeconds` so rollback is also instant.

**Time:** ~15 min · **Cost:** $0 (reuses Day-01 cluster)

---

## Blue-Green vs Canary in one table

| concern               | Canary (Day 3/4)                       | Blue-Green (this lab)                                 |
|-----------------------|----------------------------------------|-------------------------------------------------------|
| compute during deploy | +1 pod at a time                       | **2× compute** (full new RS up alongside full old RS) |
| traffic shift         | gradual (25 → 50 → 75 → 100)           | atomic flip when `activeService` selector changes     |
| validation surface    | analysis on canary pod, real users hit | analysis or manual smoke against `previewService`, **zero** real users on green |
| rollback              | `undo` → walks canary steps again      | flip back is instant — blue still warm                |
| good for              | unknown unknowns, slow burn-in         | DB migrations, breaking dep upgrades, all-or-nothing  |

---

## Architecture

```
            ┌──────────────────────────────┐
            │  ELB (Day-01) → Service web  │  ← activeService — selector pinned to BLUE RS
            └──────────────┬───────────────┘
                           │
            ┌──────────────▼──────────────┐
            │   BLUE ReplicaSet (4 pods)   │  podinfo:6.7.0   (serving real users)
            └─────────────────────────────-┘

            ┌──────────────────────────────┐
            │   Service web-preview        │  ← previewService — selector pinned to GREEN RS
            └──────────────┬───────────────┘
                           │
            ┌──────────────▼──────────────┐
            │  GREEN ReplicaSet (4 pods)   │  podinfo:6.7.1   (validation only)
            └─────────────────────────────-┘

When you `rollouts promote web`:
   activeService.spec.selector.<hash>  →  flips to GREEN hash      ← single atomic patch
   BLUE pods keep running for scaleDownDelaySeconds (60s here)     ← instant rollback window
```

After `scaleDownDelaySeconds`:
- BLUE ReplicaSet is scaled to 0 (RS object preserved per `revisionHistoryLimit`).
- GREEN becomes the new "current blue" for the next deploy.

---

## Files

| file                          | purpose                                                       |
|-------------------------------|---------------------------------------------------------------|
| `preview-service.yaml`        | `web-preview` ClusterIP — Argo pins selector to the green RS  |
| `rollout.yaml`                | Rollout with `strategy.blueGreen`, manual promotion           |
| `rollout-with-analysis.yaml`  | optional variant: `prePromotionAnalysis` gates the flip on Prometheus  |

---

## Implementation

### 0 · Pre-reqs

```bash
export KUBECONFIG="$PWD/.kubeconfig-chaos"
kubectl get svc web                                # Day-01 LoadBalancer still here
```

### 1 · Clean up any Day-3 / Day-4 leftovers (idempotent)

```bash
kubectl delete rollout web --ignore-not-found
kubectl delete svc web-canary --ignore-not-found
kubectl delete deployment loadgen --ignore-not-found     # not needed for Day-5 vanilla path
kubectl delete podmonitor web-podinfo --ignore-not-found # ditto (keep if doing analysis variant)
kubectl delete analysistemplate success-rate --ignore-not-found
kubectl delete analysisrun --all --ignore-not-found
kubectl patch svc web --type=merge -p '{"spec":{"selector":{"app":"web"}}}'
```

### 2 · Apply Day-5 manifests

```bash
cd labs/day-05-blue-green
kubectl apply -f preview-service.yaml -f rollout.yaml

sleep 30
kubectl argo rollouts get rollout web                    # Healthy, podinfo:6.7.0, 4 pods
kubectl get svc web web-preview \
  -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.spec.selector}{"\n"}{end}'
# Both Services should have the same pod-template-hash for now (no green RS yet)
```

### 3 · Trigger blue-green: spin up the GREEN ReplicaSet

```bash
kubectl argo rollouts set image web podinfo=ghcr.io/stefanprodan/podinfo:6.7.1
kubectl argo rollouts get rollout web --watch
```

Within ~15 s you should see:
- A NEW ReplicaSet (`revision:2`) spinning up to **4 pods** of `podinfo:6.7.1`.
- The OLD ReplicaSet (`revision:1`) STILL at 4 pods of `podinfo:6.7.0`.
- Total cluster pods for `app=web`: **8** (this is the 2× compute window).
- Rollout `Status: ॥ Paused — BlueGreenPause` waiting for manual promotion.

### 4 · Verify the preview privately (zero impact on real users)

```bash
# ELB still serving blue (6.7.0). podinfo's / serves HTML; use /version for plain text.
ELB=$(kubectl get svc web -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s "http://$ELB/version"                            # → 6.7.0

# In-cluster curl to web-preview goes ONLY to green pods (6.7.1)
kubectl run preview-curl --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  sh -c 'echo active:  $(curl -s http://web/version); echo preview: $(curl -s http://web-preview/version)'
# Expected:
#   active:  6.7.0
#   preview: 6.7.1
```

### 5 · Promote — atomic flip

```bash
kubectl argo rollouts promote web

# Immediately re-check the activeService selector — it's pointing at GREEN now
kubectl get svc web -o jsonpath='{.spec.selector}{"\n"}'

# ELB users now seeing 6.7.1 (CLB needs ~30s to re-converge health checks per Day-3 gotcha)
sleep 30
curl -s "http://$ELB/" | grep -oE '"version":"[^"]+"'    # "6.7.1"
```

### 6 · Demonstrate INSTANT rollback within the scaleDownDelay window

Within the 60 s grace window, the old blue RS is **still running** at full size —
rollback is just another selector flip:

```bash
kubectl argo rollouts undo web

sleep 5
kubectl get svc web -o jsonpath='{.spec.selector}{"\n"}'        # back on the old hash
kubectl argo rollouts get rollout web | head -15
# Note: undo within scaleDownDelay is INSTANT — no pod restarts, just a Service patch
```

If you wait > 60 s before `undo`, the old blue RS will already be scaled to 0,
so `undo` would then have to re-scale the old RS up first → no longer instant.

### 7 · Optional — `prePromotionAnalysis` (requires Day-4 Prometheus stack)

```bash
# Re-apply Day-4's PodMonitor + AnalysisTemplate (kube-prometheus-stack must be installed)
kubectl apply -f ../day-04-analysis-auto-canary/pod-monitor.yaml \
              -f ../day-04-analysis-auto-canary/analysis-template.yaml

# Apply the Day-5-specific loadgen that targets web-preview (not web-canary)
kubectl apply -f loadgen-preview.yaml

# Swap in the BG-with-analysis Rollout
kubectl apply -f rollout-with-analysis.yaml

# Trigger an upgrade — controller will:
#   1. spin green (4 pods of the new image, full size)
#   2. wait for green pods Ready + Prometheus scrape data
#   3. run AnalysisRun querying success-rate of green pods (loadgen feeds them)
#   4. ONLY flip activeService if successCondition (>= 0.95) holds
#   5. otherwise abort + tear down green per abortScaleDownDelaySeconds
kubectl argo rollouts set image web podinfo=ghcr.io/stefanprodan/podinfo:6.7.0
kubectl argo rollouts get rollout web --watch

# Should NOT need a manual promote — controller auto-promotes once
# AnalysisRun phase = Successful.
kubectl get analysisrun                    # one Successful AnalysisRun per rollout
```

To prove auto-abort: apply the Day-4 `rollout-bad.yaml` pattern by re-using its
`PODINFO_RANDOM_ERROR=true` env in a BG variant — or simpler, edit
`rollout-with-analysis.yaml` in place and add the env block. With ~50% 500s, the
analysis fails, controller never promotes, ELB stays on the previous good
version, green RS scales to 0 after `abortScaleDownDelaySeconds`.

---

## Done when

- [x] `kubectl get rs -l app=web` shows **two** healthy ReplicaSets during the deploy (4 + 4 pods).
- [x] `web-preview` resolves to only-green pods; `web` resolves to only-blue pods.
- [x] `rollouts promote web` flips the `web` selector to the green hash in a single API call.
- [x] `rollouts undo web` within 60 s flips it back without restarting any pods.
- [x] After 60 s the blue RS is scaled to 0 (still exists in history for `revisionHistoryLimit`).

---

## Interview Q&A

**Q1. When would you pick Blue-Green over Canary?**
When the change is all-or-nothing and partial user exposure is unacceptable — e.g.,
a backward-incompatible API where two versions in flight at once would produce
user-visible bugs, or a DB migration that needs the new code on every replica before
clients hit it. Also when validation is cheap and binary ("smoke test passes /
doesn't"), since the canary's slow drip of metrics doesn't add value over a single
green-side test. Canary wins when you want real-user-traffic confidence on a change
that's risky in aggregate but tolerable on a small slice.

**Q2. What does `scaleDownDelaySeconds` actually buy you?**
The window during which "rollback" is just a Service selector flip — no pod
restart, no image pull, no CLB churn, sub-second cutover. Outside that window,
rollback degrades to "scale up the old RS, wait for Ready, flip" — same as a
normal deploy, several minutes. The number is your "if it's broken, how fast do
you need it gone?" SLA, bounded by how much extra compute you're willing to keep
warm.

**Q3. The Rollout has `activeService` and `previewService`. Who patches them?**
The Rollout controller. On reconciliation, it inspects the current stable RS and
the latest desired RS, and writes the `rollouts-pod-template-hash` label into each
Service's `.spec.selector`. Pre-flip: `activeService` selector = old hash,
`previewService` selector = new hash. On `promote`: activeService selector flips
to the new hash; previewService either stays on the new hash (now the same as
active) or gets cleared depending on Rollout phase. This is the only mutation Argo
makes outside its own CRDs.

**Q4. What's the failure mode if I delete `web-preview` mid-rollout?**
The Rollout controller's next reconciliation will recreate it (it owns the Service
via `metadata.ownerReferences`). But during the gap, the in-cluster
`prePromotionAnalysis` would fail because its target (web-preview) doesn't
resolve → AnalysisRun Error → rollout aborts and tears down green per
`abortScaleDownDelaySeconds`. ELB traffic to blue is unaffected the whole time.

**Q5. Walk me through what `kubectl argo rollouts undo web` does within the scale-down window.**
1. CLI hits the API server, mutates `Rollout.spec.template` to point at the previous
   ReplicaSet's pod template.
2. Controller reconciliation: sees template change → identifies the matching prior RS
   (which is still scaled up because we're inside `scaleDownDelaySeconds`).
3. Patches `activeService.spec.selector.rollouts-pod-template-hash` back to the old
   hash → kube-proxy programs iptables, EndpointSlice repopulates with old pod IPs.
4. New "current desired" RS (the one we just rejected) enters its own scale-down
   timer per `abortScaleDownDelaySeconds`.
5. Total user-visible downtime: 0 (assuming CLB has both sets of nodes registered —
   typically true since both RS pods landed on the cluster's node fleet).

**Q6. `autoPromotionEnabled: true` vs `false`?**
`false` (our `rollout.yaml`) — controller spins green and **waits indefinitely**
for a `kubectl argo rollouts promote web`. Good for changes that need human
sign-off (release window, security review, manual smoke test).
`true` (our `rollout-with-analysis.yaml`) — controller spins green, runs
`prePromotionAnalysis` if defined, and auto-flips if analysis passes (or
immediately if no analysis is defined). The intersection: `autoPromotionEnabled:
true` + `prePromotionAnalysis: ...` is the canonical CD pipeline.

**Q7. We have 4 replicas of podinfo. During the cutover we briefly have 8 pods. Does that mean we need 2× the cluster?**
Only for the cutover window (`scaleDownDelaySeconds` + green ramp-up time, so
typically 1-3 min). The cluster autoscaler (Karpenter / CAS) absorbs the burst by
adding nodes if needed, then removes them after scale-down. You only pay for the
overlap. For huge fleets it's still cheaper than the alternative — a bad deploy
with no instant rollback costs more in SEV time than an extra few node-minutes a
day.
