# Cluster sizing, settings and alerting: what to change

Written 2026-11-16 from a 30-day review of the `hiresense-k8s-fra1` cluster
(Prometheus holds ~31 days), live pod config and heap profiles. Nothing here is
applied except where marked **Done**. Numbers are from Grafana/Prometheus
unless a source is named.

## Where the cluster stands

- 2 nodes, 4 vCPU and 6.7 GB allocatable each. Nodes were rotated 2026-10-29
  (18 days ago).
- CPU: 30-day peak 15 to 19% of a node, average ~6.5%. CPU requests reserve
  ~54% of each node (4.2 cores total, about 8 times real use).
- Memory: working set 5.8 GB of 13.4 GB (monitoring ~4 GB, all app pods
  ~0.6 GB). Requests reserve 75% and 65% of the two nodes (~9.4 GB).
- No OOM kills in 30 days. Restarts: kube-state-metrics 9 (last exit 2 on
  7 Nov, cause unknown), cert-manager 2, `hiresense-app` worker 1, Loki rules
  sidecar 1.
- Prometheus has fired `KubeMemoryOvercommit`, `KubeCPUOvercommit`,
  `CPUThrottlingHigh` and `PrometheusNotConnectedToAlertmanagers`, and nothing
  received them: Alertmanager is disabled and the 14 Grafana-managed rules
  cover only the app and the voice agent.

## 1. Done, not yet applied

Commit `b123d64` (helm `main`, pushed). Apply with `make upgrade-monitoring`.

| Change | File | Before | After |
| --- | --- | --- | --- |
| Tempo memory ballast off | `charts/monitoring/values.yaml` (`tempo.tempo.memBallastSizeMbs`) | 1024 (chart default) | 0 |
| Grafana memory request | `values-prod.yaml` | 256Mi | 512Mi (limit stays 1Gi) |
| Prometheus memory request | `values-prod.yaml` | 1Gi | 1536Mi |
| node-exporter CPU limit | `values.yaml` | 200m | 500m |

Why: a Tempo heap profile showed 1,024 of 1,130 MB in-use heap was the ballast
(live data ~100 MB at ~5 spans/s). Expect Tempo to fall from ~970 MB resident
to ~300 to 400 MB. Restarts Tempo (WAL replay) and Prometheus (short scrape
gap).

Verify: `container_memory_rss{pod="tempo-0"}` well under 970 MB; traces still
queryable; Prometheus targets up.

## 2. Monitoring chart: still to change

**Status 2026-11-16: 2.1 to 2.4 and the series trims below are now in the chart
(committed locally, helm template renders them; not applied).** Added at the
same time, from the "why is monitoring so big" review (Prometheus has 78,290
active series): stop scraping the DOKS API server and its four default SLO rule
groups (26k series, `kubeApiServer.enabled: false`), drop Istio ingress
request/response size histograms (~6k, PodMonitor `metricRelabelings`) and
Grafana's HTTP size histograms (~2.5k, `grafana.serviceMonitor.metricRelabelings`).
Pyroscope is kept. 2.5 and 2.6 and everything from section 3 on are still open.

All in `charts/monitoring/`. Apply together with section 1.

### 2.1 Pyroscope retention (do this instead of resizing the disk)

The pod runs the v2 storage architecture (`architecture_storage: v2`). Its
effective retention is `limits.retention_period: 31d`. The chart sets only
`compactor_blocks_retention_period: 168h`, a v1 setting (the pod reports it as
`1w`). The 10Gi volume holds 6.4 GB and grows ~77 MB a day, full around
2027-01-01.

```yaml
# values.yaml, pyroscope.pyroscope.structuredConfig
limits:
  retention_period: 168h   # v2: what actually expires data
  compactor_blocks_retention_period: 168h
```

- Space frees over about a day (compactor `deletion_delay` is 12h).
- Keep the 10Gi volume. No PVC patch, no StatefulSet recreate.
- Confirmed in the Pyroscope configuration reference:
  `compactor_blocks_retention_period` is marked "[v1 storage only]" (default
  `0s`), while `retention_period` ("Retention period for the data. 0 means data
  never deleted", default `31d`) is not v1-only. The chart set the v1-only key,
  so the 31d default has been in force. Verify after apply:
  `kubelet_volume_stats_used_bytes{persistentvolumeclaim="data-pyroscope-0"}`
  stops rising and falls.
- If it does not fall, fall back to resizing: patch the PVC to 20Gi, delete the
  StatefulSet with `--cascade=orphan`, then `helm upgrade`.

### 2.2 CPU requests (clears `KubeCPUOvercommit`)

| Component | `values-prod.yaml` key | CPU request now | Suggested |
| --- | --- | --- | --- |
| Prometheus | `kube-prometheus-stack.prometheus.prometheusSpec.resources` | 500m | 200m |
| Grafana | `kube-prometheus-stack.grafana.resources` | 200m | 100m |
| Loki | `loki.loki.resources` | 200m | 100m |
| Tempo | `tempo.tempo.resources` | 200m | 100m |

Frees ~0.7 cores of requests. Real use is 20 to 100 m each, limits unchanged.

### 2.3 Memory requests below real peak

| Component | Where | Request now | 30-day peak | Suggested |
| --- | --- | --- | --- | --- |
| Pyroscope | `values.yaml` `pyroscope.pyroscope.resources` | 256Mi | 423 MB | 512Mi |
| Alloy | `values.yaml` `pyroscope.alloy.alloy.resources` (the Alloy bundled in the Pyroscope chart) | 128Mi | 248 MB | 256Mi |

### 2.4 Tempo `GOMEMLIMIT` (optional, after the ballast is off)

Set `GOMEMLIMIT=1500MiB` (about 75% of the 2Gi limit) through the chart's
`extraEnv` so a spike cannot push Tempo into an OOM kill. Current Tempo docs
describe GOMEMLIMIT as the way to cap memory; the ballast is the legacy
mechanism (a newer chart release dropped the flag). Values path, verified in
chart 1.24.4's StatefulSet template: `tempo.tempo.extraEnv`, for example
`- {name: GOMEMLIMIT, value: 1500MiB}`.

### 2.5 Small

- `grafana-sc-dashboard` is throttled 16% of the time at a 100m CPU limit:
  raise to 200m (optional).
- Leave Loki (2Gi limit, 326 MB peak), kube-state-metrics (256Mi, 75 MB peak),
  Prometheus limits and Pyroscope's 1Gi limit alone.

### 2.6 Security: Tempo S3 credentials in a ConfigMap

The `tempo` ConfigMap contains the Spaces access key and secret key in plain
text (rendered from `values-prod.secrets.yaml`). Anything that can read
ConfigMaps in `monitoring` can read them. Move them to a Secret and inject by
environment variable, then rotate the key.

## 3. Istio

| Component | File | Request now | 30-day peak | Suggested |
| --- | --- | --- | --- | --- |
| `istio-ingressgateway` (all public traffic) | `charts/istio-gateway/values.yaml` | 40Mi | 104 MB | 128Mi |
| `istiod` (2 replicas) | `charts/istio-istiod/values.yaml` | 100Mi | 195 MB | 256Mi |

Sidecars (injected `istio-proxy`) request 40Mi and peak ~95Mi. Raising that
would add ~1 GB across ~19 pods, so leave it until there is memory headroom.

## 4. App charts

### 4.1 Right-size memory requests (frees ~1.1 GB of requests)

Limits stay as they are. All values are Mi.

| Pod | Chart file | Request now | 30-day peak | Suggested |
| --- | --- | --- | --- | --- |
| `ai-engine` (prod and staging) | `hiresense/values*.yaml` | 384 | 183 | 256 |
| `backend` (prod and staging, 2 each) | `hiresense/values*.yaml` | 192 | 54 | 96 |
| `matchengine` | `matchengine/values*.yaml` | 256 | 37 | 128 |
| `interviewhandoffworker` | `interviewhandoff/values*.yaml` | 256 | 142 (staging) | 128 to 192 |

### 4.2 Availability

- Every prod service except `backend` runs one replica: `ai-engine`,
  `worker`, both frontends, `interviewhandoff`, `interviewhandoffworker`,
  `matchengine`, `recruiter-report`.
- `interviewhandoff` is the interview path: set `replicas: 2` in
  `charts/interviewhandoff/values-prod.yaml`, add a PodDisruptionBudget
  (`minAvailable: 1`) and pod anti-affinity across nodes (+128Mi of requests).
  WebSocket transcript connections still reset when a pod restarts.
- No app workload has a PodDisruptionBudget. Add one for `backend` (2 replicas).

### 4.3 Priority

All pods run at default priority, so after a node loss monitoring pods compete
with app pods for the survivor. Create two PriorityClasses (for example
`hiresense-app` high, `hiresense-monitoring` low) and set
`priorityClassName` in the app charts and the monitoring chart.

### 4.4 Node-loss headroom

Memory requests total ~9.4 GB and CPU requests ~4.2 cores against one node's
6.7 GB and 3.89 cores, so the cluster cannot reschedule everything after losing
a node at once. Sections 2.2 and 4.1 shrink the gap but do not close it (the
bumps in sections 1, 2.3 and 3 add back ~1.5 GB). The node pool already
autoscales (min 2, max 4, see section 7), so after a node loss unschedulable
pods go Pending and the autoscaler adds a node within a few minutes. The gap is
that wait, not a hard limit: the PriorityClasses in 4.3 decide who is
rescheduled first during it.

## 5. Alerts to create in Grafana

**Status 2026-11-16: created in Grafana (folder `HireSense`, group
`hiresense-infra-alerts`, contact point `discord-hiresense`), all evaluating
healthy and normal.** Rules: volume predicted full, volume nearly full,
container OOM-killed, container restarting repeatedly, node memory above 85%,
prod pod not ready, and a seventh added to guard the others, "kube-state-metrics
down" (`absent(up{job="kube-state-metrics"} == 1)`, 10m). Not in the chart: they
live in Grafana, like the existing 14. Each uses `count by (...)` so it returns
1 per offending object. Table below is the original design.

The existing 14 rules were created in Grafana (folder `HireSense`,
`cfsw4c7xe8f0gb`) and are not in the chart, so create these there too, on the
existing Discord contact point. Datasource uid `prometheus`.

| Rule | Condition | For | Severity |
| --- | --- | --- | --- |
| Volume predicted full | `predict_linear(kubelet_volume_stats_available_bytes[6h], 4*24*3600) < 0` AND `kubelet_volume_stats_available_bytes / kubelet_volume_stats_capacity_bytes < 0.15` | 1h | warning |
| Volume nearly full | `kubelet_volume_stats_available_bytes / kubelet_volume_stats_capacity_bytes < 0.05` | 5m | critical |
| Container OOM-killed | `kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1` and a restart in the last hour | 0m | critical |
| Container restarting | `increase(kube_pod_container_status_restarts_total[1h]) > 3` | 5m | warning |
| Node memory high | `1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes > 0.85` | 10m | warning |
| Prod pod not ready | `kube_pod_status_ready{condition="false", namespace=~".*-prod"} == 1` | 5m | critical |

The disk rule requires low free space as well as a negative prediction because
the linear prediction can stay negative for days after space is freed
(Red Hat bug 1632762). Sources: kubernetes-mixin storage alerts, the
Kubermatic alerting runbook, Grafana's storage monitoring post.

Also decide about Alertmanager: it is off (`alertmanager.enabled: false`), so
the ~80 built-in kube alert rules fire to nobody and
`PrometheusNotConnectedToAlertmanagers` is always firing. Either keep it off
and silence or remove that rule, or enable Alertmanager with a Discord
receiver.

## 6. Investigated (2026-11-16)

- **kube-state-metrics restarts: harmless, no change needed.** Probably tied to
  the non-HA control plane and its maintenance window (section 7): the 7 Nov
  00:11 UTC exit and the cluster's 11 Nov 00:04 UTC update both fall inside the
  00:00 to 04:00 UTC window. The "9 in 30
  days" is five pod incarnations across the 29 Oct node rotation; the current
  pod has restarted once. Its previous container's log shows 12 "Failed to
  contact API server for /livez" warnings on 2 Nov between 06:51 and 08:26
  (control-plane connectivity, DigitalOcean-managed), and it exited with code 2
  on 7 Nov 00:11 with no error line kept. Memory was never the cause (75 MB
  against a 256Mi limit). The current pod has never missed a scrape. Optional:
  alert on `up{job="kube-state-metrics"} == 0`.
- **The 8 pods without requests: no change possible.** They are DigitalOcean's
  own: `csi-do-node` (2), `doks-telemetry-config-reloader` (2), `hubble-relay`,
  `hubble-ui`, `konnectivity-agent` (2), all in `kube-system`. DOKS reconciles
  them, so edits would be overwritten.
- **Loki and Tempo retention in Spaces: working.** Tempo has deleted 35,574
  blocks with 0 retention errors and 0 compaction errors, and holds 407 blocks
  (about 7 days). Loki's retention markers are being written for the index
  tables from the retention window on and are zero for older ones. Their
  near-empty volumes are normal (WAL only).
- **Unverified keys from the first draft, now checked:** the Alloy path
  (`pyroscope.alloy.alloy.resources`) and the Tempo `extraEnv` path
  (`tempo.tempo.extraEnv`) are in sections 2.3 and 2.4.
- **Pyroscope retention key: confirmed** in section 2.1.

Still open: nothing in this section.

## 7. DigitalOcean level (doctl, 2026-11-16)

Cluster `hiresense-k8s-fra1` (id `feb474a6-0bf1-4e58-95e3-0419379b8025`),
fra1, Kubernetes 1.36.5-do.2, created 2026-05-12, running.

| Item | Value |
| --- | --- |
| Node pool | `hiresense-user-pool-muz4xkiju`, `s-4vcpu-8gb` (4 vCPU, 8 GB, 160 GB disk), 2 nodes, autoscale min 2 / max 4 |
| Node cost | $48 per node per month, $96 for the 2 |
| Control plane | not HA (the `ha` field is absent) |
| Maintenance window | every day 00:00 UTC for 4 hours, auto-upgrade off, surge upgrade on |
| Last cluster update | 2026-11-11 00:04 UTC |
| Nodes | both created 2026-10-29 (the rotation) |

Findings:

- **Control plane is not highly available.** One API server means short outages
  during maintenance and upgrades; kube-state-metrics' "Failed to contact API
  server" warnings and the restarts at 00:04 to 00:11 UTC fit that. DOKS HA is
  a paid add-on (about $40 a month, check the current price). Everything keeps
  running during a control-plane outage, but nothing can be scheduled or
  scaled. Decide whether that is acceptable for prod.
- **Autoscaling is already on (2 to 4 nodes).** That covers a node loss and
  traffic growth, so a third permanent node is not needed now. It reacts to
  Pending pods only, so keep requests honest (section 4.1) and the priority
  classes (4.3) in place.
- **Resizing nodes will not save money.** 8 GB shared nodes are the cheapest
  size with this memory ($48). The bottleneck is memory, not CPU. Going to
  `s-4vcpu-16gb-320gb-intel` or `s-8vcpu-16gb` is $96 each, so a third 8 GB
  node ($48) is the cheaper way to add memory.
- **Managed databases for HireSense** (all single node, no standby):

  | Database | Engine | Size |
  | --- | --- | --- |
  | `hiresense-prod-db-pgsql-fra1` (prod) | PostgreSQL 18 | `db-s-1vcpu-1gb` |
  | `dc-forte-db-postgresql-fra1-65749` (staging) | PostgreSQL 18 | `db-s-1vcpu-1gb` |
  | `hiresense-prod-db-vk-fra1` (prod cache) | Valkey 8 | `db-s-1vcpu-1gb` |
  | `hiresense-cache` (staging cache) | Valkey 8 | `db-s-1vcpu-1gb` |

  The prod Postgres has 1 GB of RAM and one node: no failover, and a low
  connection ceiling (22 usable on this size, see the 2026-09-01 pool
  incident). Database utilisation was not reviewed here (doctl has no database
  metrics); check CPU, memory, connections and disk in the DigitalOcean
  dashboard before deciding on a size or a standby.
- The account also holds 16 managed databases, 4 load balancers and 11 volumes
  for other projects (kalido, sawit, outline, dc-forte); not reviewed.
- Billing and invoices are not readable with this token (403).

## 8. Apply order and checks

1. Monitoring chart (sections 1, 2, 3 Istio files): `make upgrade-monitoring`,
   then the Istio targets.
2. Check: Tempo resident memory, Pyroscope volume trend, Prometheus targets,
   no new `OOMKilled`.
3. App charts (section 4): staging first, then prod, one chart at a time.
4. Create the alert rules (section 5) and force-fire a test alert to confirm
   the Discord route.
5. Re-run the 30-day queries after a week and compare.

Rollback for any value change: revert the commit and rerun the same `make`
target.

## 9. Other open items from the same session

Not cluster sizing, listed so nothing is lost.

- QA re-run on staging with the deployed fixes. Checks: one `Function calling
  wired` per room, no `disconnected mid-interview`, no `/start` 503, one
  greeting, fewer `Ungrounded company claim blocked`, the 5-minute warning once
  after ~minute 20, `Saved ai message` to the end, and voice LLM cost in
  `llm_cost_usd_total{feature=~"voice_.*"}`.
- Cost plan Task 5: Grafana alert `increase(llm_unpriced_requests_total[1h]) >
  0` to Discord.
- Prod rollout (Phase B), each step on explicit go-ahead: promote the Go image,
  remove the `gpt-4.1` pins in the prod charts, set `GUARDRAIL_LLM_MODEL` in
  `secrets.prod.env`, `deploy.sh prod`, decide the prod wake probe.
- Own frontend: re-backfill the transcript on WebSocket reconnect.
- A local `.env` with OpenAI and Azure keys was printed in a test failure
  earlier in the session: rotate those keys if that transcript was shared.
- `MEMORY.md` is 198 lines, near the 200-line read limit: merge related
  entries onto shared lines, keeping every link.
