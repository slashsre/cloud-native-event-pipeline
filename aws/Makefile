.PHONY: up down build plan apply destroy logs dump proxy clean bootstrap-backend inspect-backend

# Compose vive en floci/ (floci + proxy nginx en el mismo proyecto,
# así comparten red y nginx resuelve `floci:4566`).
COMPOSE := docker compose -f floci/docker-compose.yaml
ENDPOINT := http://localhost:4566

# Levanta todo con un solo comando: Floci -> bootstrap backend remoto -> build lambda ->
# terraform apply -> inyecta el rest_api_id en nginx -> arranca el proxy TLS.
up:
	$(COMPOSE) up -d floci
	@echo "Waiting for Floci to be healthy..."
	@until curl -sf $(ENDPOINT)/_localstack/health >/dev/null; do sleep 1; done
	$(MAKE) bootstrap-backend
	$(MAKE) build
	$(MAKE) apply
	$(MAKE) proxy

# Inicializa el bucket S3 y la tabla DynamoDB en Floci para el backend remoto de Terraform.
bootstrap-backend:
	./scripts/bootstrap_backend.sh

# Inspecciona el archivo de estado en S3 y los locks en DynamoDB dentro de Floci.
inspect-backend:
	./scripts/inspect_backend.sh

build:
	./scripts/build_lambda.sh

plan: bootstrap-backend
	cd terraform && terraform init -input=false && terraform plan

apply: bootstrap-backend
	cd terraform && terraform init -input=false && terraform apply -auto-approve

# Renderiza el rest_api_id en el .env del compose y (re)arranca el proxy nginx.
# El id se recalcula en cada apply, así un rebuild limpio no obliga a editar nada.
proxy:
	@REST_API_ID=$$(cd terraform && terraform output -raw rest_api_id); \
	echo "REST_API_ID=$$REST_API_ID" > floci/.env; \
	REST_API_ID=$$REST_API_ID $(COMPOSE) up -d nginx; \
	echo "Ingestion endpoint (TLS): https://localhost:8443/events"

destroy:
	cd terraform && terraform destroy -auto-approve

down:
	$(COMPOSE) down

# Borra el estado local para que el siguiente `up` reconstruya desde cero.
clean: down
	rm -rf floci/data
	rm -rf terraform/.terraform terraform/.terraform.lock.hcl
	rm -f terraform/terraform.tfstate terraform/terraform.tfstate.backup floci/.env

# Dump every resource from Floci (read-only) to verify creation and inspect data.
dump:
	./scripts/dump_resources.sh

# Tail Floci's container logs (Lambda output + SQS event-source-mapping poller).
logs:
	$(COMPOSE) logs -f --tail 200 floci
