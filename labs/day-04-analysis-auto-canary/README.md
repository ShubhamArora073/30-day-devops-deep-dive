# Day 04 — Auto-promote / auto-abort canary via Prometheus AnalysisTemplate

**Goal:** remove the human from the canary loop. Argo Rollouts queries Prometheus
mid-rollout for the canary's HTTP success rate; pass → keep promoting, fail →
auto-abort. Demoed end-to-end with `kube-prometheus-stack`, `podinfo`, and a
tiny load generator.

**Time:** ~30 min · **Cost:** $0 (reuses Day-01 cluster)

---

## What changes vs Day 3

| concern              | Day 3 (manual)                          | Day 4 (analysis-driven)                                  |
|----------------------|-----------------------------------------|----------------------------------------------------------|
| who promotes?        | human `rollouts promote`                | controller, based on `AnalysisRun` verdict               |
| who aborts?          | human `rollouts abort` + `undo`         | controller, on `failureLimit` exceeded                   |
| prod traffic to canary? | yes — replica-weighted (~25%)        | **no** — `stableService` pins ELB to stable pods only    |
| signal               | eyeballs                                | PromQL on real `http_requests_total{status="..."}` data  |
| app                  | nginx (returns `Server:` header)        | `podinfo` — Go service that exposes `/metrics` natively  |

`stableService: web` makes the controller patch the `web` Service selector with
the stable RS's pod-template-hash → ELB → only stable. `canaryService: web-canary`
does the same for the canary RS. The ELB never sees a non-validated build.

---

## Architecture

```
              ┌────────────────────────────────┐
              │   ELB (Day-01) → Service web   │ ← selector pinned to stable RS
              └────────────────┬───────────────┘
                               │
                ┌──────────────▼──────────────┐
                │   stable ReplicaSet (N pods) │  podinfo (good)
                └──────────────────────────────┘

                ┌──────────────▼──────────────┐
                │  Service web-canary          │ ← selector pinned to canary RS
                └──────────────┬───────────────┘
                               │
        ┌──────────────────────┼──────────────────────────┐
        │                      │                          │
┌───────▼────────┐  ┌──────────▼──────────┐    ┌──────────▼──────────┐
│ loadgen pod    │  │  canary ReplicaSet  │    │ Prometheus (kps)    │
│ curls /        │─▶│  podinfo (K pods)   │◀──┤ scrapes /metrics    │
│ every 0.2s     │  │  serves :9898       │    │ every 15s (PodMon.) │
└────────────────┘  │  exposes /metrics   │    └──────────┬──────────┘
                    └─────────────────────┘               │
                                                          │ /api/v1/query
                                                          │
                              ┌───────────────────────────▼─────────┐
                              │ AnalysisRun (spawned per step)      │
                              │ runs PromQL 3× × 30s interval       │
                              │ successCondition: result[0] ≥ 0.95  │
                              │ failureLimit: 1                     │
                              └─────────────────────────────────────┘
```

PromQL the AnalysisTemplate runs (filtered to canary pods via `pod-hash` arg):

```promql
sum(rate(http_requests_total{namespace="default", pod=~"web-{{args.pod-hash}}-.+", status!~"5.."}[1m]))
  /
sum(rate(http_requests_total{namespace="default", pod=~"web-{{args.pod-hash}}-.+"}[1m]))
```

---

## Files

| file                      | purpose                                                     |
|---------------------------|-------------------------------------------------------------|
| `canary-service.yaml`     | ClusterIP Service — Argo patches selector to canary RS      |
| `pod-monitor.yaml`        | `PodMonitor` — tells Prometheus to scrape `app=web` pods    |
| `loadgen.yaml`            | Deployment — curl-loop hitting `web-canary` for metrics     |
| `analysis-template.yaml`  | `AnalysisTemplate` with Prometheus provider + PromQL        |
| `rollout.yaml`            | Rollout: podinfo, canary/stable services, analysis steps    |
| `rollout-bad.yaml`        | Same as `rollout.yaml` + `PODINFO_RANDOM_ERROR=true` env    |

---

## Implementation

### 0 · Pre-reqs

```bash
export KUBECONFIG="$PWD/.kubeconfig-chaos"
kubectl get rollout web 2>/dev/null && \
  echo "(cleanup Day-3 state first — see block 1 below)" || echo "clean cluster, proceed"
```

### 1 · Cleanup any prior Day-3 / Day-4 partial state (idempotent)

```bash
kubectl delete rollout web --ignore-not-found
kubectl delete svc web-canary --ignore-not-found
kubectl delete analysistemplate success-rate --ignore-not-found
kubectl delete analysisrun --all --ignore-not-found
kubectl delete deployment loadgen --ignore-not-found
kubectl delete podmonitor web-podinfo --ignore-not-found
kubectl patch svc web --type=merge -p '{"spec":{"selector":{"app":"web"}}}'
```

### 2 · Install kube-prometheus-stack (Prom + Operator + Grafana + Alertmanager + node-exporter + kube-state-metrics)

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install kps prometheus-community/kube-prometheus-stack \
  --create-namespace --namespace monitoring \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.ruleSelectorNilUsesHelmValues=false \
  --set grafana.adminPassword=admin \
  --wait --timeout 8m
```

The three `*NilUsesHelmValues=false` flags tell the chart: *"if I don't give you a
selector for PodMonitor/ServiceMonitor/PrometheusRule, leave it nil (= match all)
instead of injecting the default `release: kps` label gate"*. With the default
(`true`) you must label every monitor `release: kps` or Prometheus silently
ignores it.

### 3 · Apply Day-4 manifests

```bash
cd labs/day-04-analysis-auto-canary
kubectl apply -f canary-service.yaml \
              -f analysis-template.yaml \
              -f pod-monitor.yaml \
              -f loadgen.yaml \
              -f rollout.yaml
```

Verify Prometheus is scraping podinfo (a one-shot curl pod):

```bash
kubectl run promq --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  curl -s "http://kps-kube-prometheus-stack-prometheus.monitoring:9090/api/v1/query?query=sum%20by%20(pod,status)%20(http_requests_total%7Bnamespace%3D%22default%22,pod%3D~%22web-.%2B%22%7D)"
```

You should see JSON with one entry per podinfo pod, `status="200"`, counts climbing.

### 4 · Demo A — auto-promote on a good image

```bash
kubectl argo rollouts set image web podinfo=ghcr.io/stefanprodan/podinfo:6.7.1
kubectl argo rollouts get rollout web --watch
```

Expected (~3-4 min total):

| step | what happens                                                |
|------|-------------------------------------------------------------|
| 0/8  | canary RS scaled to 1 pod                                   |
| 1/8  | `pause 45s` — lets canary become Ready + Prometheus scrape  |
| 2/8  | `analysis` → AnalysisRun runs 3 PromQL probes 30s apart, all return ≈1.0 → Successful |
| 3/8  | `setWeight: 50` → 2 canary pods                             |
| 4/8  | `pause 30s`                                                 |
| 5/8  | `analysis` → second AnalysisRun, also Successful            |
| 6/8  | `setWeight: 75`                                             |
| 7/8  | `pause 30s`                                                 |
| 8/8  | `Healthy` — all 4 pods on podinfo:6.7.1                     |

### 5 · Demo B — auto-abort on `PODINFO_RANDOM_ERROR=true`

```bash
kubectl apply -f rollout-bad.yaml          # same image, adds env that makes ~50% of requests 500
kubectl argo rollouts get rollout web --watch
```

Expected:
- canary pod spawns, Ready (the 500s are application-level — the pod itself is healthy)
- after `pause 45s` + first analysis interval, probe sees `success_rate ≈ 0.5`
- probe #2 also fails → AnalysisRun `Failed` (we tolerated 1)
- rollout → `Degraded`, canary RS scaled to 0
- ELB still serving 100% stable podinfo:6.7.1

Inspect what value Prometheus actually returned:

```bash
kubectl get analysisrun
kubectl describe analysisrun <name>     # look at .status.metricResults[0].measurements[].value
```

Recover (either works):

```bash
kubectl apply -f rollout.yaml           # fix-forward — re-apply the good spec
# OR
kubectl argo rollouts undo web          # roll back to previous successful revision
```

### 6 · Optional — open Grafana + Prometheus UIs

```bash
kubectl -n monitoring port-forward svc/kps-kube-prometheus-stack-prometheus 9090:9090 &
kubectl -n monitoring port-forward svc/kps-grafana 3000:80 &
# Prometheus: http://localhost:9090
# Grafana:    http://localhost:3000   (admin / admin)
```

Useful PromQL to paste in Prometheus → Graph:

```promql
# request rate per pod, split by status
sum(rate(http_requests_total{namespace="default"}[1m])) by (pod, status)

# what the AnalysisTemplate evaluates (replace HASH with the canary RS hash)
sum(rate(http_requests_total{namespace="default", pod=~"web-HASH-.+", status!~"5.."}[1m]))
  /
sum(rate(http_requests_total{namespace="default", pod=~"web-HASH-.+"}[1m]))
```

---

## How it works (the napkin version)

A restaurant tests a new pasta sauce. **1 of 4 tables** gets it (`setWeight: 25`).
The kitchen has a **glass window** (`/metrics`). A **food critic** (Prometheus)
walks by every 15 s and pulls a sample — the kitchen never pushes. After a 45 s
settle, an **inspector** (`AnalysisRun`) reads the critic's notebook 3 times, 30 s
apart. He'll forgive 1 bad reading; **2 bad readings** = "yank the new dish"
(`abort` — canary RS → 0). The old menu keeps going out the whole time. `undo`
is a separate decision the manager makes later.

---

## Done when

- [x] `kubectl get podmonitor web-podinfo` exists; `kubectl -n monitoring exec ...` shows 4 podinfo targets `health=up` on Prometheus.
- [x] Demo A: `podinfo:6.7.1` promotes to stable with zero manual `promote` commands.
- [x] Demo B: `rollout-bad.yaml` triggers an AnalysisRun `Failed`; rollout `Degraded`; ELB still 100% on stable.
- [x] `kubectl get analysisrun` after both demos shows: ≥2 Successful (Demo A) + 1 Failed (Demo B).

---

## Common gotchas

- **`*NilUsesHelmValues=false`** — if you skip these flags on the helm install, every
  PodMonitor needs `labels.release: kps` or Prometheus silently ignores it. Symptom:
  PodMonitor exists, but `Status → Targets` in Prometheus has nothing for your app.
- **First-pause length** — set too low (<30 s) and the AnalysisRun's first probe
  fires before Prometheus has any data; PromQL returns empty, analysis fails. Our
  45 s + 15 s scrape interval comfortably gives 2-3 scrapes before evaluation.
- **Empty query result** — `result[0]` on an empty vector is undefined. Without an
  explicit `failureCondition`, the metric goes to `Inconclusive` (not `Failed`) and
  the AnalysisRun stalls. We use `failureCondition: len(result) == 0 || result[0] < 0.95`
  to make missing-data → Failed.
- **Pod-name regex** — PromQL `pod=~"web-{{args.pod-hash}}-.+"` matches `web-<hash>-<pod-id>`.
  If you change the Rollout's name, update the regex prefix in `analysis-template.yaml`.
- **Loadgen targets `web-canary` only** — that's why analysis ALWAYS sees canary traffic.
  In production you'd let real user traffic flow to the canary (via service mesh weighted
  routing) and skip the loadgen.
- **`abort` ≠ `undo`** — abort scales canary RS to 0 and stops there. The rollout stays
  `Degraded` until you either fix-forward (re-apply a good spec) or `undo` to the prior RS.

---

## Interview Q&A

**Q1. What's the controller actually waiting on at an `analysis` step?**
It creates an `AnalysisRun` CR using the referenced `AnalysisTemplate` + args.
The AnalysisRun controller runs `count` probes spaced `interval` apart against
the configured provider (Prometheus here). Each probe evaluates `successCondition`
and `failureCondition`. The Rollout reconciliation loop blocks on
`status.phase != Running` for the current step's AnalysisRun. On `Successful`
the step advances; on `Failed` the rollout goes `Degraded` and the canary RS
is scaled to 0.

**Q2. Why decouple `canaryService` from `stableService` instead of one Service for both RS?**
Two reasons. (1) Probe targeting — the AnalysisRun queries Prometheus filtered
to canary-pod names; users would otherwise hit canary too, polluting the metric
or worse, eating the bad UX. (2) Blast radius — until validation passes, zero
production user requests touch the canary. With the basic replica-weighted
canary from Day 3, users get partial exposure during the probe window; that's
unacceptable for changes with non-trivial blast radius (schema migrations,
breaking dependency upgrades).

**Q3. `job` provider vs `prometheus` provider — when to use which?**
`job` runs a Kubernetes Job that returns pass/fail via exit code — good for
synthetic probes, smoke tests, integration checks that don't require real
traffic. `prometheus` queries time-series collected from actual user traffic
(or loadgen, in lab) — measures real impact. Mature pipelines combine both:
`job` for fast pre-flight checks, `prometheus` for the soak. We use `prometheus`
because it's the production canonical pattern.

**Q4. What stops the canary pod from accidentally taking ELB traffic?**
The selector that `stableService: web` enforces. The Service controller's
endpoint slice for `web` only contains pods with
`labels.rollouts-pod-template-hash = <stable hash>`. Canary pods carry a
different hash, so they're never registered as endpoints on `web`, so neither
kube-proxy nor the ELB routes user traffic to them. They only serve in-cluster
traffic addressed to `web-canary` (our loadgen, here).

**Q5. Why `--set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false`?**
By default kube-prometheus-stack ships the Prometheus CR with
`podMonitorSelector: {matchLabels: {release: kps}}` as a safety gate so a
shared cluster doesn't get its Prometheus drowned by every random PodMonitor.
Setting the flag `false` says: *if I don't override the selector, leave it
unset (= match all)*. Right for a single-team / lab cluster; in a multi-tenant
prod cluster you'd keep `true` and force every monitor to opt-in with the label.

**Q6. We have `count: 3, failureLimit: 1`. How many actual failures can the AnalysisRun take?**
Exactly one — the second failure marks the AnalysisRun `Failed`. The probe loop
also short-circuits: once the failed count exceeds `failureLimit`, the controller
stops scheduling further probes for that AnalysisRun and emits the verdict.

**Q7. What's the failure mode if Prometheus goes down mid-canary?**
PromQL provider gets connection-refused → metric goes `Error`. By default, the
controller treats `Error` like `Failed`. Practical outcomes: bad image during
Prometheus outage → still aborts (safe). Good image during Prometheus outage →
also aborts (false negative). Mitigations: run Prometheus with replicas ≥ 2 +
a separate Alertmanager + an additional `web` provider in the AnalysisTemplate
as a smoke-test fallback.
