# hiresense-helm-charts

Helm charts for deploying [HireSense](https://hiresense.dc-forte.com) — an AI interview platform — on DigitalOcean Kubernetes (DOKS).

## Charts

| Chart | Description |
|-------|-------------|
| `charts/hiresense` | App: Go backend, Python AI engine, React frontend, worker |
| `charts/monitoring` | Observability: Prometheus, Grafana, Loki, Tempo, Promtail, metrics-server |

## Prerequisites

- DOKS cluster (or any K8s ≥ 1.25)
- `kubectl` + `helm` v3 configured against the cluster
- Istio installed in the cluster (provides ingress)
- cert-manager installed (provides TLS via Let's Encrypt)
- Container images published to `ghcr.io/dc-forte`

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana              https://grafana.github.io/helm-charts
helm repo add metrics-server       https://kubernetes-sigs.github.io/metrics-server/
helm repo update
```

## Quick start (dev / local)

```bash
helm dep update charts/monitoring
helm dep update charts/hiresense

kubectl create namespace monitoring
kubectl create namespace hiresense-app

helm upgrade --install monitoring ./charts/monitoring -n monitoring
helm upgrade --install hiresense  ./charts/hiresense  -n hiresense-app
```

## Production deploy

Copy the secrets example, fill in real values (never commit the secrets file):

```bash
cp charts/hiresense/values-prod.secrets.example.yaml  charts/hiresense/values-prod.secrets.yaml
cp charts/monitoring/values-prod.secrets.example.yaml charts/monitoring/values-prod.secrets.yaml
# edit both files
```

Deploy:

```bash
# Observability stack first (Prometheus + metrics-server must be up before app ServiceMonitors)
helm upgrade --install monitoring ./charts/monitoring -n monitoring \
  -f charts/monitoring/values-prod.yaml \
  -f charts/monitoring/values-prod.secrets.yaml

# App
helm upgrade --install hiresense ./charts/hiresense -n hiresense-app \
  -f charts/hiresense/values-prod.yaml \
  -f charts/hiresense/values-prod.secrets.yaml
```

## Secrets

Secrets are injected at deploy time via `values-prod.secrets.yaml` (gitignored).
The example files document every required key — fill from `terraform output` or your secrets manager.

| Key group | Source |
|-----------|--------|
| DB / Redis / Mongo URLs | DigitalOcean managed databases |
| JWT / session secrets | `openssl rand -hex 32` |
| OpenAI, LiveKit, SMTP | Respective dashboards |
| DO Spaces keys | DigitalOcean → API → Spaces Keys |

## CI / releases

Pushing to `main` under `charts/**` triggers [chart-releaser](https://github.com/helm/chart-releaser-action), which packages charts and publishes them to the `gh-pages` branch as a Helm repo.

To consume a released chart:

```bash
helm repo add dc-forte https://dc-forte.github.io/hiresense-helm-charts
helm repo update
helm install hiresense dc-forte/hiresense -n hiresense-app -f your-values.yaml
```

## Observability

The monitoring chart ships a complete observability stack:

- **Prometheus** scrapes app ServiceMonitors in any namespace
- **Grafana** at `grafana.dc-forte.com` with pre-loaded dashboards (node-exporter, K8s pods, Go runtime, Loki, Tempo)
- **Loki** receives structured JSON logs from Promtail; correlates with Tempo traces via `trace_id`
- **Tempo** receives OTLP traces (gRPC :4317 / HTTP :4318) from backend + worker
- **metrics-server** serves the Kubernetes Metrics API (`metrics.k8s.io`) — required for `kubectl top`, HPA, and cluster management tools

## Using Luxury Yacht

[Luxury Yacht](https://github.com/luxury-yacht/app) is a cross-platform desktop app for browsing and managing Kubernetes clusters. It connects to your cluster via your existing kubeconfig and provides a real-time view of workloads, pods, logs, and resource metrics.

### Connect

Point it at the same kubeconfig you use with `kubectl`:

```
~/.kube/config   (default; DOKS context is added by: doctl kubernetes cluster kubeconfig save <cluster-name>)
```

Open Luxury Yacht, select the cluster from the context list, and it connects immediately.

### Resource metrics (CPU / memory)

Luxury Yacht queries `metrics.k8s.io` (the Kubernetes Metrics API) to display live CPU and memory usage per node and pod. This API is served by **metrics-server**, which is included in the monitoring chart.

If you see:

> **Metrics API not found! metrics-server may not be installed in the cluster.**

metrics-server is not running. Deploy or upgrade the monitoring chart:

```bash
helm dep update charts/monitoring
helm upgrade --install monitoring ./charts/monitoring -n monitoring \
  -f charts/monitoring/values-prod.yaml \
  -f charts/monitoring/values-prod.secrets.yaml

# Verify
kubectl -n monitoring rollout status deployment metrics-server
kubectl top nodes
```

DOKS-specific note: the monitoring chart already sets `--kubelet-preferred-address-types=InternalIP` so metrics-server can reach DOKS nodes without TLS issues.

### Useful views

| View | What to look for |
|------|-----------------|
| Nodes | CPU / memory utilisation per node (needs metrics-server) |
| Workloads → hiresense-app | Pod restarts, image tags, replica counts |
| Workloads → monitoring | Prometheus, Grafana, Loki, Tempo health |
| Logs | Live pod logs (backed by the Kubernetes log API, not Loki) |
| Services | Istio gateway, backend, AI engine endpoints |
