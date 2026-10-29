# Kubernetes 1.35.9 to 1.36.5 upgrade checklist

Cluster `hiresense-k8s-fra1` (id `feb474a6-0bf1-4e58-95e3-0419379b8025`),
kubeconfig context `do-fra1-hiresense-k8s-fra1`. Prod and staging share this
cluster, split by namespace.

Prepared 2026-10-29. Every check below was run against the live cluster on
that date unless marked "not verified".

## Verdict

No blockers found for 1.36.5. DOKS offers exactly one target from 1.35.9:
`1.36.5-do.2`. 1.37 stays blocked (see the last section).

## Compatibility

- Istio 1.30.7 supports Kubernetes 1.32 to 1.36. [Istio releases][istio]
- cert-manager v1.21.3 supports Kubernetes 1.33 to 1.36.
  [cert-manager releases][certmgr]
- kube-prometheus-stack chart 87.18.0 (operator v0.92.1): chart allows
  `>=1.25`. The upstream kube-prometheus table lists 0.18 and 0.19 as
  supporting 1.36. Mapping chart 87.18.0 to a release branch: not verified.
- Loki 3.6.8, Tempo 2.9.0, Pyroscope 2.1.1, metrics-server 0.8.1, Promtail
  3.5.1: no `kubeVersion` constraint in their charts. Not verified against
  1.36.
- DOKS-managed parts (Cilium, CSI, node agents) are upgraded by DO.

## 1.36 changes checked against this cluster

- Service `spec.externalIPs` is deprecated, not removed. Count in cluster:
  0. [Kubernetes blog][extip]
- `gitRepo` volumes are permanently disabled. Count in cluster: 0 pods.
  Controllers and CronJobs were not scanned separately.
- kube-proxy IPVS: not applicable. Cilium runs with kube-proxy replacement
  enabled and there is no kube-proxy ConfigMap.
- ingress-nginx retirement: not used, Istio is the ingress.
- Stricter IP and CIDR validation (KEP-4858) rejects leading-zero octets and
  CIDRs with host bits set on create or update. Existing objects are kept.
  Not verified: grep the chart sources for CIDR values.
- Fine-grained kubelet authorization is GA. Existing roles keep working
  because the kubelet falls back to `nodes/proxy`. [Kubernetes blog][kubelet]
  Your scrapers all hold `nodes/metrics` or `nodes/proxy`. Promtail and Alloy
  use `nodes/proxy`, which still works. Narrowing them is optional.
- Deprecated API usage: only `v1 Endpoints` is requested, and it is not
  removed.
- Nodes: containerd 1.7.29 on Debian 13. No runtime change needed.
- API removals for 1.36: not verified. The Kubernetes deprecation guide page
  could not be read in full. Re-run the deprecated API metric below on the day.

## Decide before the day

- Prod right-sizing is not deployed. Prod still runs 2 replicas of
  `ai-engine` and both frontends with the old requests. The 2-node pool is at
  87 percent and 82 percent requested memory. The upgrade surges extra nodes
  (surge upgrade is on, pool max is 4), so it fits, but headroom is thin.
  Choose one:
  - deploy the prod right-sizing first, after the staging bake is clean, or
  - upgrade first and right-size afterwards.
- Prod single replicas: after right-sizing, `ai-engine` and both frontends
  run 1 replica. A node drain evicts the only pod. Expect about 30 to 60
  seconds of downtime for each during node rotation. A PDB would block drains
  forever with one replica, so do not add one.
- Pick quiet hours. The maintenance window is 00:00 UTC for 4 hours, any day.
  Auto upgrade is off, so nothing starts on its own.

## Cleanup before the day

- Delete the leftover `regtest` pod in `default` (status `Error`).
- Decide about the unused `istio-egressgateway`. It is an old istioctl
  Deployment at 1.29.2, owned by no chart, with 0 requests in 24 hours.
- Optional: remove `default/bookinfo-gateway`, a Gateway left from the deleted
  Bookinfo app.
- Everything is pushed. `main` should match `origin/main` and the deployed
  chart versions.

## DO pre-upgrade warnings

Expected list (all accepted, none block the upgrade):

- hostPath volumes on node-exporter and Promtail. Both read host files.
- Grafana pod uses a block volume without a StatefulSet. Moving it would lose
  the Grafana SQLite data, including the service account token.

The injector webhook warning ("Mutating webhook is configured in such a way
that it may be problematic during upgrades") was cleared on 2026-10-29. DO's
open source `clusterlint` raises it when a webhook is not `Ignore`, covers
pods, and its namespace selector matches `kube-system`. The `rev.object` and
`object` injector webhooks matched every unlabelled namespace. The fix is a
label that lives only in the cluster, not in any chart:

```bash
kubectl --context do-fra1-hiresense-k8s-fra1 label namespace kube-system \
  istio-injection=disabled
```

- Do not label `istio-system`. The ingress gateway pods live there and need
  the `object` webhook for injection.
- If the warning returns, check that `kube-system` still has the label.
- The chart keeps `failurePolicy: Fail` on purpose. `Ignore` would let a
  gateway pod start un-injected and stick on image `auto`.

## Pre-flight commands

All read-only. Expect clean output.

```bash
C=do-fra1-hiresense-k8s-fra1
kubectl --context $C get nodes
kubectl --context $C get pods -A \
  --field-selector=status.phase!=Running,status.phase!=Succeeded
kubectl --context $C get ds -A | awk '$3!=$5'
kubectl --context $C get --raw /metrics \
  | grep apiserver_requested_deprecated_apis
helm --kube-context $C list -A
kubectl --context $C get certificate -A
make mem
make mem-oom
```

Also confirm:

- Only `v1 Endpoints` appears in the deprecated API metric, and its
  `removed_release` is empty.
- `kubectl get pdb -A` shows `istiod` and `istio-ingressgateway` allowing 1
  disruption.
- All 4 hiresense domains return 200.
- No pod has the literal image `auto`.
- The `ha` field in `doctl kubernetes cluster get <id> -o json` is noted, so
  you can see it is unchanged afterwards.

## Start the upgrade

```bash
doctl kubernetes cluster get-upgrades feb474a6-0bf1-4e58-95e3-0419379b8025
doctl kubernetes cluster upgrade feb474a6-0bf1-4e58-95e3-0419379b8025 \
  --version 1.36.5-do.2
```

There is no downgrade. If something breaks, roll forward.

## During the upgrade

Watch in a second terminal:

```bash
C=do-fra1-hiresense-k8s-fra1
kubectl --context $C get nodes -w
kubectl --context $C get pods -A \
  --field-selector=status.phase!=Running,status.phase!=Succeeded
kubectl --context $C -n istio-system get pods -o wide
```

Failure modes seen on the 1.34 to 1.35 upgrade:

- API server `EOF` or timeouts while the control plane restarts. Wait and
  retry.
- An ingress gateway pod stuck in `ImagePullBackOff` with image `auto`. This
  was fixed since: the injector webhook now fails instead of letting a pod
  through un-injected, so the pod should retry. If one is stuck, delete it.
- A DaemonSet pod (for example Promtail) stuck Pending because the node it is
  pinned to is full. Free memory on that node by deleting a staging replica.
- Pods packed onto two nodes while the third is empty after rotation. Nothing
  rebalances.
- A short staging 503 while sidecars reconnect. Prod has no sidecars.
- Single-replica prod blips, as described above.

Run `kubectl rollout status` on `deploy/istiod` before anything that creates
gateway pods.

## After the upgrade

- `doctl kubernetes cluster get <id>` shows 1.36.5-do.2 and `running`.
- All nodes `Ready` on v1.36.5. `ha` unchanged from before.
- No un-injected `image: auto` pods. No Pending pods.
- DaemonSets all ready equals desired. Check per-node requested memory with
  `make mem-requests`.
- Gateway has 2 ready endpoints, both on proxyv2 1.30.7.
- `istiod` 2 of 2. cert-manager 3 of 3. Certificates all Ready.
- Monitoring: Prometheus targets for kubelet still up, Grafana loads, Loki
  receives logs from every node.
- All 4 sites return 200, plus `/api/health` on prod and staging.
- Update the memory note and this file with what actually happened.

## 1.37 and later

Not ready:

- Istio 1.30 tops out at Kubernetes 1.36. 1.31 supports 1.37, but there is no
  stable 1.31 Helm chart yet (only alpha, beta and rc builds).
- cert-manager 1.21 tops out at 1.36. A release for 1.37 was not available.
- Istio 1.30 end of life is around December 2026, so 1.31 is needed anyway.

[istio]: https://istio.io/latest/docs/releases/supported-releases/
[certmgr]: https://cert-manager.io/docs/releases/
[extip]: https://kubernetes.io/blog/2026/05/14/kubernetes-v1-36-deprecation-and-removal-of-service-externalips/
[kubelet]: https://kubernetes.io/blog/2026/04/24/kubernetes-v1-36-fine-grained-kubelet-authorization-ga
