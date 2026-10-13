# Análisis Técnico y Propuesta de Mejoras — AWS Serverless Event Ingestion Pipeline

## 1. Resumen Ejecutivo y Evaluación Actual

El repositorio implementa una solución sólida, bien pensada y completamente funcional para el **AWS Serverless Event Ingestion Pipeline**, utilizando **Floci (LocalStack 2.0.1)** como emulador local de AWS, **Terraform** como motor de Infraestructura como Código (IaC), un proxy inverso **Nginx** para terminación TLS estricta y una arquitectura serverless desacoplada y orientada a eventos.

### Cumplimiento de Requisitos del Reto
| Requisito | Estado | Observación |
|---|:---:|---|
| Despliegue con un solo comando (`make up`) | ✅ | Orquestación limpia vía Makefile. |
| Ingesta HTTPS con certificado de confianza (sin `-k`) | ✅ | Nginx TLS proxy + OpenSSL SAN (`localhost`, `127.0.0.1`, `host.docker.internal`). |
| Autenticación con API Key desde Secrets Manager | ✅ | Generación aleatoria, guardado en Secrets Manager y adjuntado a Usage Plan. |
| Desacoplamiento API Gateway ➔ SQS | ✅ | Integración directa AWS Service sin función síncrona intermedia. |
| Cola de mensajes fallidos (SQS DLQ) | ✅ | Configurada con `maxReceiveCount = 5` y retención de 14 días. |
| Consumo vía Lambda Event Source Mapping | ✅ | Batching de 10 mensajes con `ReportBatchItemFailures`. |
| Doble persistencia (DynamoDB + S3 con prefijo temporal) | ✅ | Registro estructurado + copia cruda en `raw/YYYY/MM/DD/<id>.json`. |
| Idempotencia ante reintentos de SQS | ✅ | `sha256(payload)` como clave + PutItem condicional + S3 previo. |
| Principio de menor privilegio (IAM) | ✅ | Roles específicos por componente sin `Action: "*"` ni `Resource: "*"`. |
| Evidencias y Dumps finales | ✅ | Directorios `dump-cloud/` y `logs/` generados. |
| Integración con Frontend Kubernetes | ✅ | `server.py` envía eventos de acceso con validación TLS. |

---

## 2. Fortalezas Destacadas de la Implementación

1. **Integración Directa API Gateway ➔ SQS:**
   Haber evitado una Lambda "pasarela" en el camino síncrono reduce la latencia, elimina un punto de fallo/concurrencia y optimiza costes significativamente.
2. **Estrategia de Idempotencia Robusta:**
   Calcular el identificador único determinista a partir del hash del payload crudo (`sha256`) y persistir en S3 antes del Put condicional en DynamoDB (`attribute_not_exists(event_id)`) previene que fallos intermedios impidan el archivado crudo en reintentos.
3. **Manejo Exhaustivo de Incidencias (`TROUBLESHOOTING.md`):**
   El análisis del fallo de segmentación del provider AWS con `aws_api_gateway_api_key` debido a la ausencia de `createdDate` en Floci y su resolución mediante `null_resource` / AWS CLI demuestra una profunda capacidad de depuración y comprensión interna de los SDKs de Terraform y AWS.
4. **Seguridad y Validación TLS Real:**
   Configurar SANs multi-dominio en OpenSSL para permitir la validación estricta con `--cacert` tanto desde el host (`localhost`) como desde pods de Kubernetes (`host.docker.internal`) sin saltarse la verificación de certificados.

---

## 3. Propuesta de Mejoras Técnicas

```
                  ┌────────────────────────────────────────────────────────┐
                  │          EJES DE MEJORA DEL PIPELINE AWS              │
                  └────────────────────────────────────────────────────────┘
                                              │
         ┌──────────────────┬─────────────────┼──────────────────┬──────────────────┐
         ▼                  ▼                 ▼                  ▼                  ▼
  [1. API Gateway]    [2. Lambda Core]   [3. Storage]    [4. Testing/CI]    [5. Paridad Prod]
   - Request Valid.    - Boto3 reuse      - S3 SSE/Life   - Tests unitarios  - Abstracción
   - Rate limiting     - Modelo DynamoDB  - DDB PITR/TTL  - Tests E2E auto   - ACM / Route53
   - Access logging    - Log estructurado - SQS KMS enc.  - Linters / SAST   - Extensiones IaC
```

---

### Eje 1: Ingesta y API Gateway

#### 1.1 Validación de Esquema en el Borde (Request Validation)
* **Situación actual:** Cualquier petición enviada al endpoint (incluso un JSON corrupto, vacío o sin campos requeridos) es aceptada por API Gateway con `HTTP 200 {"status":"accepted"}` y encolada en SQS. El error solo se descubre cuando la Lambda intenta procesarlo. Si el cuerpo no es un JSON válido, la Lambda lo reintenta hasta 5 veces antes de enviarlo a la DLQ.
* **Mejora:** Configurar un `aws_api_gateway_request_validator` y un `aws_api_gateway_model` con JSON Schema Draft 4 en el método `POST /events`.
* **Beneficio:** API Gateway rechaza peticiones mal formadas con `400 Bad Request` en milisegundos, protegiendo la cola SQS, evitando ejecuciones inútiles de Lambda y ahorrando costes.

#### 1.2 Rate Limiting y Quotas en el Usage Plan
* **Situación actual:** El recurso `aws_api_gateway_usage_plan.this` asocia el API key y el stage, pero no tiene configurado `throttle_settings` ni `quota_settings`.
* **Mejora:** Definir límites por cliente:
  ```hcl
  throttle_settings {
    burst_limit = 100
    rate_limit  = 50
  }
  quota_settings {
    limit  = 100000
    period = "DAY"
  }
  ```
* **Beneficio:** Evita ataques de denegación de servicio (DoS) y consumo descontrolado de recursos.

#### 1.3 Logging de Acceso en API Gateway
* **Situación actual:** No hay logs de acceso HTTP configurados en API Gateway.
* **Mejora:** Añadir `aws_api_gateway_method_settings` o `access_log_settings` hacia un CloudWatch Log Group formateado en JSON con `$context.identity.sourceIp`, `$context.responseLength`, `$context.status`, `$context.requestId`.

---

### Eje 2: Función Lambda y Modelo de Datos

#### 2.1 Optimización de Inicialización de Boto3
* **Situación actual:** En `lambda/ingest_processor/handler.py`:
  ```python
  def _persist(raw_body: str) -> None:
      ...
      table = dynamodb.Table(TABLE_NAME)  # Se ejecuta por cada registro de cada batch
  ```
* **Mejora:** Mover la inicialización de `table = dynamodb.Table(TABLE_NAME)` al ámbito global (a nivel de módulo), junto con `dynamodb` y `s3`.
* **Beneficio:** Se aprovecha el contexto de ejecución caliente (warm start) de AWS Lambda, evitando instanciar el objeto de tabla de DynamoDB en cada iteración del bucle de mensajes.

#### 2.2 Enriquecimiento de Atributos en DynamoDB (Indexación)
* **Situación actual:** DynamoDB almacena únicamente tres columnas:
  - `event_id` (Partition Key)
  - `raw_payload` (String con el JSON completo)
  - `received_at` (Timestamp ISO)
  Para consultar eventos por usuario, IP, dominio o tipo de acción, se requiere un `Scan` completo con `contains(raw_payload, :val)` (como se indica en el README, línea 417), lo cual es costoso y de baja escalabilidad.
* **Mejora:** Parsear campos estándar si vienen presentes y guardarlos como atributos nativos de DynamoDB:
  ```python
  payload = json.loads(body)
  item = {
      "event_id": event_id,
      "raw_payload": body,
      "received_at": now.isoformat(),
      "user": payload.get("user", "unknown"),
      "domain": payload.get("domain", "unknown"),
      "action": payload.get("action", "unknown"),
      "client_ip": payload.get("client_ip", "unknown"),
  }
  ```
  Se puede añadir un Global Secondary Index (GSI) sobre `domain` o `user` con `received_at` como Sort Key para permitir consultas rápidas y eficientes.

#### 2.3 Logging Estructurado y Correlación
* **Situación actual:** Si ocurre una excepción en el handler, se captura de forma genérica con `except Exception:` sin emitir un log detallado de la traza ni el identificador del mensaje en CloudWatch.
* **Mejora:** Incorporar el módulo estándar `logging` con formato JSON o la librería `aws-lambda-powertools[all]` para inyectar contexto (`aws_request_id`, `message_id`, `event_id`) y emitir métricas personalizadas (ej. eventos procesados, duplicados detectados).

#### 2.4 Control de Dependencias en el Empaquetado
* **Situación actual:** `requirements.txt` contiene `boto3>=1.34.0`, el cual es instalado por `build_lambda.sh` dentro del ZIP.
* **Mejora:** AWS Lambda incluye `boto3` y `botocore` de forma predeterminada en su runtime de Python 3.12. No empaquetarlo en el ZIP reduce el tamaño del artefacto de ~40 MB a unos pocos KB, acelerando el despliegue y reduciendo el tiempo de cold-start.

---

### Eje 3: Seguridad y Resiliencia en Almacenamiento

#### 3.1 Cifrado en Reposo (Encryption at Rest)
* **S3:** Añadir recurso `aws_s3_bucket_server_side_encryption_configuration` (usando `AES256` o KMS).
* **DynamoDB:** Activar `server_side_encryption { enabled = true }`.
* **SQS:** Configurar `sqs_managed_sse_enabled = true` en la cola principal y en la DLQ.

#### 3.2 Ciclo de Vida y Retención (Data Lifecycle & TTL)
* **S3 Lifecycle Rules:** Definir una política de transición de logs crudos hacia `GLACIER` o expiración tras N días (`aws_s3_bucket_lifecycle_configuration`).
* **DynamoDB TTL:** Activar un atributo de Time-To-Live (`ttl { attribute_name = "ttl", enabled = true }`) para depurar automáticamente registros antiguos de acceso y mantener la tabla compacta y económica.

#### 3.3 Alertas y Observabilidad en SQS DLQ
* **Situación actual:** La DLQ acumula mensajes fallidos, pero no hay mecanismo proactivo que notifique si un mensaje entra en la DLQ.
* **Mejora:** Crear una alarma de CloudWatch (`aws_cloudwatch_metric_alarm`) sobre la métrica `ApproximateNumberOfMessagesVisible > 0` de la DLQ con notificación hacia un topic SNS.

#### 3.4 Gestión de Certificados y Claves Privadas
* **Situación actual:** El archivo `certs/nginx/server-key.pem` está commiteado en el repositorio git.
* **Mejora:** Aunque sea para un entorno local de prueba, comitear claves privadas es un antipatrón. El script de generación o el `Makefile` debería generar el certificado y la clave si no existen localmente (agregando los `.pem` al `.gitignore`).

---

### Eje 4: Automatización de Pruebas y CI/CD

#### 4.1 Test de Integración Automatizado (`make test`)
* **Situación actual:** La verificación del pipeline se realiza mediante comandos `curl` y llamadas al CLI de AWS documentados en `ARCHITECTURE.md` y `README.md`.
* **Mejora:** Crear un script de pruebas automatizado (`scripts/test_pipeline.sh`) e integrarlo en el `Makefile`:
  - Envía evento válido ➔ Comprueba HTTP 200.
  - Verifica que el mensaje se procese y desaparezca de SQS.
  - Verifica que el registro exista en DynamoDB y S3.
  - Envía el mismo evento ➔ Verifica idempotencia (recuento no sube).
  - Envía mensaje inválido directamente a SQS ➔ Verifica llegada a DLQ.

#### 4.2 Tests Unitarios para la Lambda
* **Mejora:** Crear un directorio `tests/` con pruebas unitarias usando `pytest` y `moto` (o mocking de `boto3`) para validar la lógica del handler sin necesidad de levantar Docker ni Floci.

#### 4.3 Linters y Análisis Estático de Código / IaC
* Añadir targets de validación:
  - `terraform fmt -check` y `terraform validate`.
  - `tflint` para buenas prácticas de Terraform.
  - `ruff` / `flake8` / `black` para el código Python.
  - `checkov` o `trivy` para análisis de seguridad de IaC.
* Integrar un workflow de **GitHub Actions** (`.github/workflows/ci.yml`) que ejecute estos chequeos en cada Pull Request.

---

### Eje 5: Paridad Local (Floci) vs Producción (AWS Real)

El proyecto cuenta con adaptaciones específicas para lidiar con limitaciones de Floci:
1. `null_resource` con AWS CLI para evitar el crash del provider al crear la API Key.
2. `timestamp()` en el deployment de API Gateway para forzar el snapshot tras un re-apply.
3. Proxy inverso Nginx en el puerto 8443 (en AWS real, API Gateway proporciona HTTPS nativo o Custom Domains con ACM).
4. Variable de entorno `AWS_ENDPOINT_URL = "http://localhost.localstack.cloud:4566"`.

**Propuesta:** Introducir un flag `variable "is_local" { default = true }` en Terraform:
- Si `is_local == false`:
  - Se utiliza el recurso oficial `aws_api_gateway_api_key`.
  - No se inyecta `AWS_ENDPOINT_URL` en la Lambda (apunta al AWS real de forma nativa).
  - No se fuerza el re-deploy con `timestamp()`.
  - Se puede provisionar un `aws_api_gateway_domain_name` con certificado ACM en lugar del proxy Nginx.

---

### Eje 6: Extensiones Arquitectónicas Opcionales

Posibles extensiones arquitectónicas:
1. **Eje Adicional: Backend Remoto de Terraform en S3 + DynamoDB:**
   Configurar el estado remoto de Terraform para que se guarde en un bucket S3 de Floci con control de bloqueo mediante una tabla DynamoDB (`terraform-locks`).
2. **Eje Adicional: Orquestación con Step Functions:**
   Sustituir el ESM directo entre SQS y Lambda por una State Machine de Step Functions con bloques `Retry` (backoff exponencial) y `Catch` que redirijan a la DLQ.
3. **Eje Adicional: Certificado ACM modelado en Terraform:**
   Declarar el recurso `aws_acm_certificate` en Terraform para modelar la infraestructura de certificados en la capa de control.
4. **Eje Adicional: Integración con Kubernetes:** *(Ya completado exitosamente en el repo).*

---

## 4. Guía de Implementación de Mejoras Clave

### Ejemplo 1: Validación de Peticiones en API Gateway (`modules/ingestion_api/main.tf`)

```hcl
# Validador de peticiones
resource "aws_api_gateway_request_validator" "body_validator" {
  name                        = "${var.name_prefix}-body-validator"
  rest_api_id                 = aws_api_gateway_rest_api.this.id
  validate_request_body       = true
  validate_request_parameters = false
}

# Modelo JSON Schema para validar el payload
resource "aws_api_gateway_model" "event_schema" {
  rest_api_id  = aws_api_gateway_rest_api.this.id
  name         = "EventModel"
  description  = "Esquema JSON requerido para /events"
  content_type = "application/json"

  schema = jsonencode({
    "$schema" = "http://json-schema.org/draft-04/schema#"
    title     = "EventPayload"
    type      = "object"
    required  = ["event_id"]
    properties = {
      event_id = { type = "string", minLength = 1 }
      user     = { type = "string" }
      action   = { type = "string" }
      domain   = { type = "string" }
    }
  })
}

# Actualizar el método POST para usar el validador y el modelo
resource "aws_api_gateway_method" "post_events" {
  rest_api_id          = aws_api_gateway_rest_api.this.id
  resource_id          = aws_api_gateway_resource.events.id
  http_method          = "POST"
  authorization        = "NONE"
  api_key_required     = true
  request_validator_id = aws_api_gateway_request_validator.body_validator.id

  request_models = {
    "application/json" = aws_api_gateway_model.event_schema.name
  }
}
```

---

### Ejemplo 2: Handler Optimizado e Indexado (`handler.py`)

```python
import hashlib
import json
import logging
import os
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Inicialización a nivel de módulo (reutilización en warm starts)
ENDPOINT_URL = os.environ.get("AWS_ENDPOINT_URL")
dynamodb = boto3.resource("dynamodb", endpoint_url=ENDPOINT_URL)
s3 = boto3.client("s3", endpoint_url=ENDPOINT_URL)

TABLE_NAME = os.environ["DYNAMODB_TABLE"]
BUCKET_NAME = os.environ["S3_BUCKET"]
table = dynamodb.Table(TABLE_NAME)


def _event_id(raw_body: str) -> str:
    return hashlib.sha256(raw_body.encode("utf-8")).hexdigest()


def _persist(raw_body: str) -> None:
    event_id = _event_id(raw_body)
    now = datetime.now(timezone.utc)
    payload = json.loads(raw_body)

    # 1. Archivar en S3
    key = f"raw/{now:%Y/%m/%d}/{event_id}.json"
    s3.put_object(
        Bucket=BUCKET_NAME,
        Key=key,
        Body=raw_body.encode("utf-8"),
        ContentType="application/json",
    )

    # 2. Persistir en DynamoDB con atributos extra para búsquedas eficientes
    item = {
        "event_id": event_id,
        "raw_payload": raw_body,
        "received_at": now.isoformat(),
        "user": str(payload.get("user", "anonymous")),
        "action": str(payload.get("action", "unknown")),
        "domain": str(payload.get("domain", "unknown")),
        "client_ip": str(payload.get("client_ip", "unknown")),
    }

    try:
        table.put_item(
            Item=item,
            ConditionExpression="attribute_not_exists(event_id)",
        )
        logger.info(json.dumps({"msg": "event_persisted", "event_id": event_id}))
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            logger.info(json.dumps({"msg": "duplicate_ignored", "event_id": event_id}))
            return
        logger.error(json.dumps({"msg": "dynamodb_error", "error": str(exc)}))
        raise


def handler(event, context):
    batch_item_failures = []

    for record in event.get("Records", []):
        msg_id = record.get("messageId", "unknown")
        try:
            body = record["body"]
            _persist(body)
        except Exception as err:
            logger.error(json.dumps({
                "msg": "record_processing_failed",
                "message_id": msg_id,
                "error": str(err),
            }))
            batch_item_failures.append({"itemIdentifier": msg_id})

    return {"batchItemFailures": batch_item_failures}
```

---

### Ejemplo 3: Script de Test de Integración Automatizado (`scripts/test_pipeline.sh`)

```bash
#!/usr/bin/env bash
set -euo pipefail

ENDPOINT="${FLOCI_ENDPOINT:-http://localhost:4566}"
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=us-east-1

awsl() { aws --endpoint-url="$ENDPOINT" "$@"; }

echo "=== 1. Obteniendo credenciales y endpoints ==="
KEY=$(awsl secretsmanager get-secret-value --secret-id event-pipeline/ingestion-api-key --query SecretString --output text)
URL="https://localhost:8443/events"

echo "=== 2. Test Happy Path (HTTPS + API Key) ==="
STATUS=$(curl -s -o /dev/null -w "%{http_code}" --cacert certs/nginx/server.pem "$URL" \
  -H "x-api-key: $KEY" -H "Content-Type: application/json" \
  -d '{"event_id":"ci-evt-1","user":"tester","action":"login"}')

if [ "$STATUS" -ne 200 ]; then
  echo "❌ Error: Se esperaba HTTP 200, recibido: $STATUS"
  exit 1
fi
echo "✅ HTTP 200 recibido correctamente."

echo "=== 3. Esperando procesamiento de Lambda (3s) ==="
sleep 3

COUNT=$(awsl dynamodb scan --table-name event-pipeline-access-events --select COUNT --query Count --output text)
echo "Items en DynamoDB: $COUNT"

if [ "$COUNT" -lt 1 ]; then
  echo "❌ Error: No se encontró el registro en DynamoDB"
  exit 1
fi
echo "✅ Registro confirmado en DynamoDB."
echo "🎉 ¡Todos los tests de integración pasaron con éxito!"
```

---

## 5. Matriz de Priorización de Mejoras

| Mejora | Impacto | Esfuerzo | Prioridad |
|---|:---:|:---:|:---:|
| **Validación de esquema en API Gateway** | Alto | Bajo | **P0 (Inmediata)** |
| **Reutilización de Boto3 Table en Lambda** | Medio | Bajo | **P0 (Inmediata)** |
| **Extracción de atributos indexados en DynamoDB** | Alto | Bajo | **P1 (Alta)** |
| **Test de integración automatizado (`make test`)** | Alto | Medio | **P1 (Alta)** |
| **Cifrado y ciclo de vida en S3/DynamoDB/SQS** | Medio | Bajo | **P2 (Media)** |
| **No versionar `server-key.pem` en Git** | Alto | Bajo | **P2 (Media)** |
| **Logging estructurado con correlación** | Medio | Medio | **P2 (Media)** |
| **Remote State + ACM TF** | Alto | Medio | **P3 (Deseable)** |
| **Step Functions Workflow** | Medio | Alto | **P3 (Opcional)** |
