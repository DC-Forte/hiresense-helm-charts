CHARTS_DIR := charts
# Every deploy target is pinned to the HireSense DOKS cluster regardless of the
# shell's current kube context (a stray `docker-desktop` context once got a fresh
# helm install attempted against it). Override with KUBE_CONTEXT=... if needed.
KUBE_CONTEXT ?= do-fra1-hiresense-k8s-fra1
HELM_UPGRADE_FLAGS := --kube-context $(KUBE_CONTEXT) --server-side=true --force-conflicts

.PHONY: help dep-update dep-update-monitoring \
	upgrade-monitoring adopt-istio-gateway upgrade-istio-gateway upgrade-cert-manager \
	adopt-istio upgrade-istio-base upgrade-istiod \
	upgrade-hiresense-staging upgrade-hiresense-prod \
	upgrade-recruiter-report-staging upgrade-recruiter-report-prod \
	upgrade-matchengine-staging upgrade-matchengine-prod \
	upgrade-interviewhandoff-staging upgrade-interviewhandoff-prod \
	upgrade-all-staging upgrade-all-prod \
	mem mem-nodes mem-requests mem-pods mem-oom

KUBECTL = kubectl --context $(KUBE_CONTEXT)

help:
	@echo "make mem                                 # all memory checks below"
	@echo "make mem-nodes                           # actual memory/CPU use per node (metrics-server)"
	@echo "make mem-requests                        # memory/CPU REQUESTED vs allocatable per node (what the scheduler sees)"
	@echo "make mem-pods                            # top 20 pods by actual memory use"
	@echo "make mem-oom                             # pods whose last restart was an OOM kill"
	@echo "make upgrade-monitoring                  # helm upgrade --install monitoring"
	@echo "make adopt-istio-gateway                 # ONE-TIME: annotate live gateway objects so Helm can adopt them"
	@echo "make upgrade-istio-gateway               # helm upgrade --install istio-gateway"
	@echo "make upgrade-cert-manager                # helm upgrade --install cert-manager"
	@echo "make adopt-istio                         # ONE-TIME: annotate live istio base+istiod objects so Helm can adopt them"
	@echo "make upgrade-istio-base                  # helm upgrade --install istio-base (CRDs; run BEFORE istiod)"
	@echo "make upgrade-istiod                      # helm upgrade --install istiod"
	@echo "make upgrade-hiresense-staging            # helm upgrade --install hiresense (staging)"
	@echo "make upgrade-hiresense-prod               # helm upgrade --install hiresense-prod (prod)"
	@echo "make upgrade-recruiter-report-staging      # helm upgrade --install recruiter-report-staging (TAG=<sha> to override)"
	@echo "make upgrade-recruiter-report-prod         # helm upgrade --install recruiter-report-prod (TAG=<sha> to override)"
	@echo "make upgrade-matchengine-staging           # helm upgrade --install matchengine (staging)"
	@echo "make upgrade-matchengine-prod              # helm upgrade --install matchengine-prod (prod)"
	@echo "make upgrade-interviewhandoff-staging       # helm upgrade --install interviewhandoff (staging)"
	@echo "make upgrade-interviewhandoff-prod          # helm upgrade --install interviewhandoff-prod (prod)"
	@echo "make upgrade-all-staging                   # upgrade monitoring, hiresense, recruiter-report, matchengine, interviewhandoff (staging)"
	@echo "make upgrade-all-prod                      # upgrade hiresense, recruiter-report, matchengine, interviewhandoff (prod)"
	@echo "make dep-update                           # helm dep update for all charts"

dep-update-monitoring:
	helm dep update $(CHARTS_DIR)/monitoring

dep-update-istio-gateway:
	helm dep update $(CHARTS_DIR)/istio-gateway

dep-update-cert-manager:
	helm dep update $(CHARTS_DIR)/cert-manager

dep-update-istio-base:
	helm dep update $(CHARTS_DIR)/istio-base

dep-update-istiod:
	helm dep update $(CHARTS_DIR)/istio-istiod

dep-update: dep-update-monitoring dep-update-istio-gateway dep-update-cert-manager dep-update-istio-base dep-update-istiod

# Istio control plane, adopted in place from the original `istioctl install`.
# ONE-TIME order:  make adopt-istio  ->  make upgrade-istio-base  ->  make upgrade-istiod
# Then clean up the two legacy "default revision tag" objects istioctl created. They
# would double-inject next to the chart's active istio-sidecar-injector webhook
# (injection is idempotent, so it is harmless, just redundant):
#   kubectl --context $(KUBE_CONTEXT) delete mutatingwebhookconfiguration istio-revision-tag-default
#   kubectl --context $(KUBE_CONTEXT) -n istio-system delete svc istiod-revision-tag-default
# Behavior change to know about: the chart's injector webhook is failurePolicy=Fail
# (live tag webhook was Ignore). A pod needing injection can no longer be created
# un-injected while istiod is down; it fails and is retried. Keep istiod at 2 replicas.
adopt-istio:
	@set -e; \
	adopt() { rel=$$1; shift; for r in "$$@"; do \
		$(KUBECTL) -n istio-system annotate $$r meta.helm.sh/release-name=$$rel meta.helm.sh/release-namespace=istio-system --overwrite; \
		$(KUBECTL) -n istio-system label $$r app.kubernetes.io/managed-by=Helm --overwrite; \
	done; }; \
	adopt istio-base $$($(KUBECTL) get crd -o name | grep 'istio.io') \
		serviceaccount/istio-reader-service-account validatingwebhookconfiguration/istiod-default-validator; \
	adopt istiod deployment/istiod service/istiod serviceaccount/istiod role/istiod rolebinding/istiod \
		configmap/istio configmap/istio-sidecar-injector configmap/values poddisruptionbudget/istiod \
		clusterrole/istiod-clusterrole-istio-system clusterrole/istiod-gateway-controller-istio-system clusterrole/istio-reader-clusterrole-istio-system \
		clusterrolebinding/istiod-clusterrole-istio-system clusterrolebinding/istiod-gateway-controller-istio-system clusterrolebinding/istio-reader-clusterrole-istio-system \
		mutatingwebhookconfiguration/istio-sidecar-injector validatingwebhookconfiguration/istio-validator-istio-system

upgrade-istio-base: dep-update-istio-base
	helm upgrade --install istio-base $(CHARTS_DIR)/istio-base -n istio-system \
		-f $(CHARTS_DIR)/istio-base/values.yaml \
		$(HELM_UPGRADE_FLAGS)

upgrade-istiod: dep-update-istiod
	helm upgrade --install istiod $(CHARTS_DIR)/istio-istiod -n istio-system \
		-f $(CHARTS_DIR)/istio-istiod/values.yaml \
		$(HELM_UPGRADE_FLAGS)

# Release name MUST stay `cert-manager` (matches the live release; keeps resource names).
upgrade-cert-manager: dep-update-cert-manager
	helm upgrade --install cert-manager $(CHARTS_DIR)/cert-manager -n cert-manager \
		-f $(CHARTS_DIR)/cert-manager/values.yaml \
		$(HELM_UPGRADE_FLAGS)

# ONE-TIME, before the first upgrade-istio-gateway. Only same-named objects need
# adopting (Deployment, Service, PDB); the chart creates its own SA/Role/RoleBinding.
# PREREQ: istiod must be HA first. The chart uses gateway injection (image: auto)
# and the injector webhook is failurePolicy=Ignore: a gateway pod created while
# istiod is down starts un-injected and sticks in ImagePullBackOff.
adopt-istio-gateway:
	for r in deploy/istio-ingressgateway svc/istio-ingressgateway pdb/istio-ingressgateway; do \
		kubectl --context $(KUBE_CONTEXT) -n istio-system annotate $$r meta.helm.sh/release-name=istio-gateway meta.helm.sh/release-namespace=istio-system --overwrite && \
		kubectl --context $(KUBE_CONTEXT) -n istio-system label $$r app.kubernetes.io/managed-by=Helm --overwrite; \
	done

upgrade-istio-gateway: dep-update-istio-gateway
	helm upgrade --install istio-gateway $(CHARTS_DIR)/istio-gateway -n istio-system \
		-f $(CHARTS_DIR)/istio-gateway/values.yaml \
		$(HELM_UPGRADE_FLAGS)

upgrade-monitoring: dep-update-monitoring
	helm upgrade --install monitoring $(CHARTS_DIR)/monitoring -n monitoring \
		-f $(CHARTS_DIR)/monitoring/values-prod.yaml \
		-f $(CHARTS_DIR)/monitoring/values-prod.secrets.yaml \
		$(HELM_UPGRADE_FLAGS)

upgrade-hiresense-staging:
	helm upgrade --install hiresense $(CHARTS_DIR)/hiresense -n hiresense-app \
		-f $(CHARTS_DIR)/hiresense/values-staging.yaml \
		-f $(CHARTS_DIR)/hiresense/values-staging.secrets.yaml \
		$(HELM_UPGRADE_FLAGS)

# Do not run until build.yml (go-backend) ships a real :prod image tag —
# see docs/superpowers/specs/2026-09-11-hiresense-staging-prod-buildout-design.md Phase 4.
upgrade-hiresense-prod:
	helm upgrade --install hiresense-prod $(CHARTS_DIR)/hiresense -n hiresense-app-prod --create-namespace \
		-f $(CHARTS_DIR)/hiresense/values-prod.yaml \
		-f $(CHARTS_DIR)/hiresense/values-prod.secrets.yaml \
		$(HELM_UPGRADE_FLAGS)

# values-staging.yaml/values-prod.yaml pin image.tag to the real per-env tag CI pushes
# (":staging"/":prod") — a plain upgrade no longer ErrImagePulls. TAG=<sha> pins an exact build.
upgrade-recruiter-report-staging:
	helm upgrade --install recruiter-report-staging $(CHARTS_DIR)/recruiter-report -n recruiter-report-staging \
		-f $(CHARTS_DIR)/recruiter-report/values-staging.yaml \
		-f $(CHARTS_DIR)/recruiter-report/values-staging.secrets.yaml \
		$(if $(TAG),--set image.tag=$(TAG)) \
		$(HELM_UPGRADE_FLAGS)

upgrade-recruiter-report-prod:
	helm upgrade --install recruiter-report-prod $(CHARTS_DIR)/recruiter-report -n recruiter-report-prod \
		-f $(CHARTS_DIR)/recruiter-report/values-prod.yaml \
		-f $(CHARTS_DIR)/recruiter-report/values-prod.secrets.yaml \
		$(if $(TAG),--set image.tag=$(TAG)) \
		$(HELM_UPGRADE_FLAGS)

upgrade-matchengine-staging:
	helm upgrade --install matchengine $(CHARTS_DIR)/matchengine -n matchengine-staging --create-namespace \
		-f $(CHARTS_DIR)/matchengine/values.yaml \
		-f $(CHARTS_DIR)/matchengine/values-staging.yaml \
		-f $(CHARTS_DIR)/matchengine/values-staging.secrets.yaml \
		$(HELM_UPGRADE_FLAGS)

upgrade-matchengine-prod:
	helm upgrade --install matchengine-prod $(CHARTS_DIR)/matchengine -n matchengine-prod --create-namespace \
		-f $(CHARTS_DIR)/matchengine/values.yaml \
		-f $(CHARTS_DIR)/matchengine/values-prod.yaml \
		-f $(CHARTS_DIR)/matchengine/values-prod.secrets.yaml \
		$(HELM_UPGRADE_FLAGS)

upgrade-interviewhandoff-staging:
	helm upgrade --install interviewhandoff $(CHARTS_DIR)/interviewhandoff -n interviewhandoff-staging --create-namespace \
		-f $(CHARTS_DIR)/interviewhandoff/values.yaml \
		-f $(CHARTS_DIR)/interviewhandoff/values-staging.yaml \
		-f $(CHARTS_DIR)/interviewhandoff/values-staging.secrets.yaml \
		$(HELM_UPGRADE_FLAGS)

upgrade-interviewhandoff-prod:
	helm upgrade --install interviewhandoff-prod $(CHARTS_DIR)/interviewhandoff -n interviewhandoff-prod --create-namespace \
		-f $(CHARTS_DIR)/interviewhandoff/values.yaml \
		-f $(CHARTS_DIR)/interviewhandoff/values-prod.yaml \
		-f $(CHARTS_DIR)/interviewhandoff/values-prod.secrets.yaml \
		$(HELM_UPGRADE_FLAGS)

upgrade-all-staging: upgrade-monitoring upgrade-hiresense-staging upgrade-recruiter-report-staging upgrade-matchengine-staging upgrade-interviewhandoff-staging

upgrade-all-prod: upgrade-hiresense-prod upgrade-matchengine-prod upgrade-interviewhandoff-prod
# --- memory checks (read-only) -------------------------------------------------
# Three different numbers: usage (top), requests (what blocks scheduling, e.g. a
# pinned DaemonSet pod going Pending), limits (the OOM ceiling, ~4x overcommitted).
mem: mem-nodes mem-requests mem-pods mem-oom

mem-nodes:
	$(KUBECTL) top nodes

mem-requests:
	@for n in $$($(KUBECTL) get nodes -o name); do \
		echo "== $$n"; \
		$(KUBECTL) describe $$n | grep -A6 'Allocated resources' | grep -E 'cpu|memory'; \
	done

mem-pods:
	$(KUBECTL) top pods -A --sort-by=memory | head -21

mem-oom:
	@out=$$($(KUBECTL) get pods -A -o json | jq -r '.items[] | select(.status.containerStatuses[]?.lastState.terminated.reason=="OOMKilled") | "\(.metadata.namespace)/\(.metadata.name)"' | sort -u); \
	echo "$${out:-none}"
