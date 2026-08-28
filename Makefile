CHARTS_DIR := charts
HELM_UPGRADE_FLAGS := --server-side=true --force-conflicts

.PHONY: help dep-update dep-update-monitoring \
	upgrade-monitoring upgrade-hiresense \
	upgrade-recruiter-report-staging upgrade-recruiter-report-prod \
	upgrade-matchengine-staging upgrade-interviewhandoff-staging \
	upgrade-all

help:
	@echo "make upgrade-monitoring                  # helm upgrade --install monitoring"
	@echo "make upgrade-hiresense                    # helm upgrade --install hiresense"
	@echo "make upgrade-recruiter-report-staging      # helm upgrade --install recruiter-report-staging (TAG=<sha> to override)"
	@echo "make upgrade-recruiter-report-prod         # helm upgrade --install recruiter-report-prod (TAG=<sha> to override)"
	@echo "make upgrade-matchengine-staging           # helm upgrade --install matchengine (staging-only, no prod yet)"
	@echo "make upgrade-interviewhandoff-staging       # helm upgrade --install interviewhandoff (staging-only, no prod yet)"
	@echo "make upgrade-all                          # upgrade monitoring, hiresense, recruiter-report (staging+prod), matchengine, interviewhandoff"
	@echo "make dep-update                           # helm dep update for all charts"

dep-update-monitoring:
	helm dep update $(CHARTS_DIR)/monitoring

dep-update: dep-update-monitoring

upgrade-monitoring: dep-update-monitoring
	helm upgrade --install monitoring $(CHARTS_DIR)/monitoring -n monitoring \
		-f $(CHARTS_DIR)/monitoring/values-prod.yaml \
		-f $(CHARTS_DIR)/monitoring/values-prod.secrets.yaml \
		$(HELM_UPGRADE_FLAGS)

upgrade-hiresense:
	helm upgrade --install hiresense $(CHARTS_DIR)/hiresense -n hiresense-app \
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

upgrade-interviewhandoff-staging:
	helm upgrade --install interviewhandoff $(CHARTS_DIR)/interviewhandoff -n interviewhandoff-staging --create-namespace \
		-f $(CHARTS_DIR)/interviewhandoff/values.yaml \
		-f $(CHARTS_DIR)/interviewhandoff/values-staging.yaml \
		-f $(CHARTS_DIR)/interviewhandoff/values-staging.secrets.yaml \
		$(HELM_UPGRADE_FLAGS)

upgrade-all: upgrade-monitoring upgrade-hiresense upgrade-recruiter-report-staging upgrade-recruiter-report-prod upgrade-matchengine-staging upgrade-interviewhandoff-staging
