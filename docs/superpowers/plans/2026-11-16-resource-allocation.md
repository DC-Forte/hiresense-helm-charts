# Resource allocation: use the current 2 nodes well

**Status 2026-11-16: phases 1 and 2 are in the charts (committed locally,
rendered with `helm template` for every chart and env; not applied).** Apply
order matters: upgrade the `monitoring` chart first (it creates the
PriorityClasses the app charts name), then staging charts, then prod one chart
at a time. Phases 3 (load test) and 4 (database) are open.

Written 2026-11-16. Goal: get the most out of the cluster we already pay for
(2 x `s-4vcpu-8gb`, $96 a month, autoscale 2 to 4) without adding nodes. Data:
30 days of Prometheus plus live pod config. Companion to
`2026-11-16-cluster-sizing-and-alerting.md` (monitoring, alerts, DigitalOcean).
Nothing here is applied.

## What the data says

- **Traffic is tiny.** Prod request rate over 7 days: 0.0023 req/s
  (`hiresense-app-prod`) and 0.0009 req/s (`interviewhandoff-prod`), about 200
  and 76 requests a day. p95 latency 5 to 11 ms. No app pod is CPU throttled.
- **CPU is idle.** 30-day p99 CPU per app container: 0.4 to 29 m for every prod
  pod. The one exception is the staging `interviewhandoffworker` at 388 m
  (template generation bursts, 4 times its 100m request, under its 500m limit).
  Nodes average ~6.5% CPU.
- **Memory is the only real limit,** and monitoring (~4 GB of 5.8 GB) uses most
  of it. All app pods together use ~0.6 GB.
- **Prod is a single point of failure for most services.** Only `backend` runs 2
  replicas. A restart or node drain of any other prod pod is an outage for that
  service (and each deploy resets `interviewhandoff` WebSocket transcript
  connections).
- **Adding pods does not add capacity at this load.** There is no throughput to
  gain from more replicas; the gains are availability, honest scheduling and
  keeping prod ahead of monitoring and staging. If "performance" means speed for
  users, the limits are outside the cluster: the 1 vCPU / 1 GB single-node prod
  Postgres (transaction pooler of 20 server connections, shared by all services),
  LLM latency and LiveKit. More pods do not raise the 20-connection ceiling.

## Principles

1. Requests equal real use plus headroom (about the 95th percentile). Limits
   stay generous; they cost nothing until used.
2. Prod gets scheduling priority over monitoring over staging, and replicated
   prod pods spread across both nodes.
3. Add replicas only where the service is stateless and a second copy is safe.
   Queue workers stay at 1 until their job claim is proven safe.
4. Measure capacity with a load test before setting autoscaling targets.

## Target allocation

Memory in Mi, CPU in millicores, per pod. "Now" is the live request.

### Prod

| Workload | Replicas now to target | Memory request now to target | CPU request now to target | 30-day peak (mem / cpu) |
| --- | --- | --- | --- | --- |
| `hiresense-backend` | 2 to 2 | 192 to 128 | 50 to 50 | 41 Mi / 12 m |
| `hiresense-ai-engine` | 1 to 2 | 384 to 256 | 75 to 75 | 183 Mi / 29 m |
| `hiresense-worker` | 1 to 1 | 128 to 128 | 25 to 25 | 42 Mi / 9 m |
| `frontend-candidate`, `frontend-recruiter` | 1 to 2 each | 32 to 32 | 20 to 20 | 9 Mi / <1 m |
| `interviewhandoff` | 1 to 2 | 128 to 128 | 25 to 50 | 42 Mi / 1 m |
| `interviewhandoffworker` | 1 to 1 | 256 unchanged | 100 to 100 | 47 Mi prod, 142 Mi staging (ffmpeg clips and template generation burst; a comment in the chart records a 595 Mi staging peak) |
| `matchengine` | 1 to 2 | 256 to 128 | 200 to 100 | 26 Mi / 1 m |
| `recruiter-report` | 1 to 2 | 128 to 128 | 25 to 25 | 59 Mi / 7 m (job claim uses `FOR UPDATE SKIP LOCKED`, so a second copy is safe) |

Limits stay as they are. Totals are in the budget below.

### Staging (everything at 1 replica)

| Workload | Replicas now to target | Memory request now to target | CPU request now to target |
| --- | --- | --- | --- |
| `hiresense-backend` | 2 to 1 | 192 to 128 | 50 to 50 |
| `hiresense-ai-engine` | 1 to 1 | 384 to 256 | 75 to 75 |
| others | unchanged | unchanged | unchanged |

### Placement and resilience (prod)

- `topologySpreadConstraints` on every replicated prod deployment: spread by
  `kubernetes.io/hostname`, `maxSkew: 1`, `whenUnsatisfiable: ScheduleAnyway`,
  so both replicas land on different nodes when possible.
- `PodDisruptionBudget` `minAvailable: 1` for `backend`, `ai-engine`,
  `interviewhandoff`, `matchengine` and both frontends.
- PriorityClasses: `hiresense-prod` (highest), `hiresense-monitoring`,
  `hiresense-staging` (lowest). Prod and the ingress gateway outrank everything;
  monitoring outranks staging because losing it blinds you while losing staging
  hurts no user.
- `interviewhandoff` rollout: `maxUnavailable: 0`, `maxSurge: 1`, a
  `preStop` sleep and `terminationGracePeriodSeconds` of at least 60 so
  in-flight WebSocket transcript connections drain before the pod exits.
- Wake probe already keeps a LiveKit agent worker warm (`LIVEKIT_KEEPALIVE_ENABLED`).

### Verify before scaling a worker or `recruiter-report`

The workers (`hiresense-worker`, `interviewhandoffworker`) and the
`recruiter-report` job loop claim work from the database. Confirm each claim is
atomic (`FOR UPDATE SKIP LOCKED` or equivalent) before running more than one
copy, or two pods could process the same job and double the LLM spend.

## Budget

Application pods, memory requests (Mi):

| | Now | Target |
| --- | --- | --- |
| Prod | 1,792 | 2,048 |
| Staging | 1,600 | 1,216 |
| Istio sidecars (40 Mi each; 20 pods now, 25 after: +6 prod, -1 staging) | 800 | 1,000 |
| Total | 4,192 | 4,264 |

So prod gets 6 more pods and a second copy of every stateless service while the
application memory request stays about level (+70 Mi): the staging trim and the
smaller `backend`, `ai-engine` and `matchengine` requests pay for the new copies. CPU requests: ~1,030 m now,
~1,170 m target.

Cluster, with the monitoring and Istio changes from the companion plan: memory
requests rise from ~9.4 GB to ~10.8 GB of 13.4 GB allocatable (81%), because
those requests move up to real use. CPU requests fall from 4.2 to ~3.6 cores of
7.8. Real working set drops from 5.8 GB to ~5 GB once Tempo's ballast is off.
If a node is lost, Pending pods trigger the node autoscaler (max 4) and the
priority order above decides who is rescheduled first.

## Phases

1. **Staging first.** Apply the staging rows, spread constraints, PDBs and
   PriorityClasses. Watch for Pending pods and eviction.
2. **Prod, one chart at a time:** `hiresense`, then `matchengine`, then
   `interviewhandoff`. Between each, check pods Ready, no restarts, and the
   Grafana alerts quiet.
3. **Load test before autoscaling.** Use k6 against staging `interviewhandoff`
   (start, WebSocket transcript, concurrent interviews) and `backend`, find the
   concurrency one pod handles, then add an HPA (CPU 60 to 70% of request,
   min 2, max 4) only where the test shows CPU or memory is the limit. The
   autoscaler adds a node when HPAs need room.
4. **Database tier.** Review the prod Postgres in the DigitalOcean dashboard
   (CPU, memory, connections, disk). A standby and a larger size are the real
   performance and availability upgrade; this plan does not touch them.

## Rollback

Each change is a values edit: revert the commit and rerun the chart's `make
upgrade-...` target. Replica changes roll back instantly. Request changes
restart the pod once.
