.PHONY: help up down aws-up aws-down aws-destroy aws-dump aws-bootstrap-backend aws-inspect-backend k8s-up k8s-down k8s-verify clean

.DEFAULT_GOAL := help

help: ## Show this help message
	@echo "Cloud-Native Event Pipeline - Master Makefile"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

# ----------------------------------------------------------------------------
# Full Stack Orchestration
# ----------------------------------------------------------------------------
up: aws-up k8s-up ## Start full stack: AWS local environment (Floci) + Kubernetes (Kind)
	@echo ""
	@echo "================================================================="
	@echo ">> Cloud-Native Event Pipeline is fully initialized and running!"
	@echo "================================================================="

down: k8s-down aws-down ## Tear down full stack: Kubernetes + AWS resources

# ----------------------------------------------------------------------------
# AWS / Floci Targets
# ----------------------------------------------------------------------------
aws-up: ## Provision Floci, bootstrap remote backend, build Lambda, apply Terraform, start TLS proxy
	@echo ">> Starting AWS local infrastructure..."
	$(MAKE) -C aws up

aws-down: ## Tear down AWS local infrastructure
	@echo ">> Stopping AWS local infrastructure..."
	$(MAKE) -C aws down

aws-destroy: ## Destroy Terraform resources in AWS
	$(MAKE) -C aws destroy

aws-dump: ## Dump created AWS resources for inspection
	$(MAKE) -C aws dump

aws-bootstrap-backend: ## Initialize S3 bucket & DynamoDB lock table for remote state in Floci
	$(MAKE) -C aws bootstrap-backend

aws-inspect-backend: ## Inspect Terraform remote state file in S3 and locks in DynamoDB
	$(MAKE) -C aws inspect-backend

# ----------------------------------------------------------------------------
# Kubernetes Targets
# ----------------------------------------------------------------------------
k8s-up: ## Start Kind cluster, CoreDNS, registry, ingress, and deploy workloads
	@echo ">> Starting Kubernetes cluster & microservices..."
	$(MAKE) -C k8s up

k8s-down: ## Tear down Kubernetes cluster and local registry
	@echo ">> Stopping Kubernetes cluster..."
	$(MAKE) -C k8s down

k8s-verify: ## Check health of Kubernetes workloads and ingress
	$(MAKE) -C k8s verify

# ----------------------------------------------------------------------------
# Maintenance
# ----------------------------------------------------------------------------
clean: k8s-down ## Clean all local state, containers, caches and temporary files
	$(MAKE) -C aws clean
