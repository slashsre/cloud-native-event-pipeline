# ============================================================================
# Kubernetes Stack - Makefile
#
# Runs the resources present in this module:
#
#   make up     -> registry + cluster + coredns + images + ingress + deploy
#   make down   -> tear everything down (delete cluster + registry)
#
# Run `make help` to list all targets.
# ============================================================================

# ---- Configuration (override on the CLI, e.g. `make up CLUSTER_NAME=foo`) ---
CLUSTER_NAME ?= event-pipeline-cluster
NODE_IMAGE   ?= kindest/node:v1.34.0
KIND_CONFIG  ?= cluster/kind-configuration.yaml
COREDNS_CM   ?= cluster/coredns-configmap.yaml

REG_NAME     ?= kind-registry
REG_PORT     ?= 5000
REGISTRY     ?= localhost:5000
IMAGE_TAG    ?= 1.0.0

NS           ?= event-pipeline
APPS_DIR     ?= apps
MANIFESTS    ?= manifests

.DEFAULT_GOAL := help

.PHONY: help up down registry cluster coredns images ingress deploy verify clean

# ----------------------------------------------------------------------------
help: ## Show this help
	@echo "Kubernetes Stack - available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

# ----------------------------------------------------------------------------
# Orchestration
# ----------------------------------------------------------------------------
up: registry cluster coredns images ingress deploy ## Bring the whole stack up
	@echo ""
	@echo ">> Stack is up. Validate with: make verify"

down: clean ## Tear everything down (alias of clean)

# ----------------------------------------------------------------------------
# Local container registry
# ----------------------------------------------------------------------------
registry: ## Start the local docker registry (kind-registry:5000)
	@if [ "$$(docker inspect -f '{{.State.Running}}' $(REG_NAME) 2>/dev/null || true)" != 'true' ]; then \
		echo ">> Starting registry $(REG_NAME) on 127.0.0.1:$(REG_PORT)"; \
		docker run -d --restart=always -p "127.0.0.1:$(REG_PORT):5000" \
			--network bridge --name $(REG_NAME) registry:3; \
	else \
		echo ">> Registry $(REG_NAME) already running"; \
	fi

# ----------------------------------------------------------------------------
# kind cluster (control-plane + 1 worker)
# ----------------------------------------------------------------------------
cluster: ## Create the kind cluster and connect the registry to its network
	kind create cluster \
		--name $(CLUSTER_NAME) \
		--image $(NODE_IMAGE) \
		--config=$(KIND_CONFIG)
	@echo ">> Connecting registry to the kind network"
	@docker network connect kind $(REG_NAME) 2>/dev/null || true

# ----------------------------------------------------------------------------
# CoreDNS rewrite rules for the server alternative names (DNS resolution)
# ----------------------------------------------------------------------------
coredns: ## Apply CoreDNS rewrite rules and restart CoreDNS
	kubectl -n kube-system apply -f $(COREDNS_CM)
	kubectl -n kube-system rollout restart deployment coredns
	kubectl -n kube-system rollout status deployment coredns --timeout=90s

# ----------------------------------------------------------------------------
# Build & push app images to the local registry
# ----------------------------------------------------------------------------
images: ## Build and push client/server images to the local registry
	docker build -t $(REGISTRY)/client-app:$(IMAGE_TAG) $(APPS_DIR)/client-app-1.0.0/
	docker build -t $(REGISTRY)/server-app:$(IMAGE_TAG) $(APPS_DIR)/server-app-1.0.0/
	docker push $(REGISTRY)/client-app:$(IMAGE_TAG)
	docker push $(REGISTRY)/server-app:$(IMAGE_TAG)

# ----------------------------------------------------------------------------
# ingress-nginx via Helm
# ----------------------------------------------------------------------------
ingress: ## Install ingress-nginx (NodePort + hostPort) via Helm and wait for it
	helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
	helm repo update
	helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
		--namespace ingress-nginx --create-namespace \
		--set controller.service.type=NodePort \
		--set controller.service.externalTrafficPolicy=Local \
		--set controller.hostPort.enabled=true \
		--set-string controller.nodeSelector.ingress-ready=true \
		--set controller.config.use-forwarded-headers=true \
		--set controller.config.compute-full-forwarded-for=true
	kubectl wait --namespace ingress-nginx \
		--for=condition=ready pod \
		--selector=app.kubernetes.io/component=controller \
		--timeout=120s

# ----------------------------------------------------------------------------
# Deploy the microservices (secrets -> workloads -> ingress)
# ----------------------------------------------------------------------------
deploy: ## Apply namespace, secrets, services, deployments and ingress
	kubectl apply -f $(MANIFESTS)/namespace.yaml
	# server: secrets first (TLS secret created dynamically from certs/, keeping private keys out of Git)
	@if [ ! -f "certs/server.key" ]; then \
		openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout certs/server.key -out certs/server.crt -config certs/san.cnf -extensions v3_ca; \
	fi
	kubectl create secret tls server-tls-secret -n $(NS) \
		--cert=certs/server.crt --key=certs/server.key --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -f $(MANIFESTS)/server-app-1.0.0/server-backend-ca.yaml
	kubectl apply -f $(MANIFESTS)/server-app-1.0.0/service.yaml
	kubectl apply -f $(MANIFESTS)/server-app-1.0.0/deployment.yaml
	kubectl apply -f $(MANIFESTS)/server-app-1.0.0/ingress.yaml
	# client
	kubectl apply -f $(MANIFESTS)/client-app-1.0.0/client-secret.yaml
	kubectl apply -f $(MANIFESTS)/client-app-1.0.0/service.yaml
	kubectl apply -f $(MANIFESTS)/client-app-1.0.0/deployment.yaml
	kubectl -n $(NS) rollout status deployment/server --timeout=120s
	kubectl -n $(NS) rollout status deployment/client --timeout=120s

# ----------------------------------------------------------------------------
# Validation helper
# ----------------------------------------------------------------------------
verify: ## Quick health checks (nodes, pods, endpoints, ingress)
	kubectl get nodes -o wide
	kubectl get pods -n ingress-nginx -o wide
	kubectl get pods,svc,ingress -n $(NS) -o wide

# ----------------------------------------------------------------------------
# Teardown
# ----------------------------------------------------------------------------
clean: ## Delete the kind cluster and the local registry
	-kind delete cluster --name $(CLUSTER_NAME)
	-docker rm -f $(REG_NAME)
